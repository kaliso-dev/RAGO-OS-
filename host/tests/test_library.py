#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tests de la bibliothèque partagée, côté Linux (module M7) :
# host/lib/rago_library.py et host/bin/rago-library.sh.
#
# Sans root : règle de sûreté (écriture ou lecture seule), requêtes, réglages,
# lecture des fiches de jeux, contrôle NTFS sur des volumes NTFS fabriqués
# octet par octet (journal vide, propre, sale, version 2.0, chkdsk, fixups
# cassés, journal en deux morceaux).
#
# En root (conteneur jetable ou VM) en plus : vraie RAGO-COMM (FAT32 si le noyau
# la connaît, sinon ext4) montée par un faux systemctl, vraie RAGO-LIB sur un
# périphérique loop — NTFS avec le pilote ntfs3 si le noyau l'a et que mkntfs
# est là (VM), sinon ext4 avec RAGO_LIB_REQUIRE_NTFS=0 (conteneur) —, et
# rago-library.sh de bout en bout : lecture seule au doute, écriture seulement
# si Windows a écrit « off », requêtes, liste, garde d'hibernation.
#
# Usage : python3 host/tests/test_library.py [-v]
import importlib.machinery
import importlib.util
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
HELPER = os.path.join(REPO, "host", "lib", "rago_library.py")
SCRIPT = os.path.join(REPO, "host", "bin", "rago-library.sh")
loader = importlib.machinery.SourceFileLoader("rago_library", HELPER)
spec = importlib.util.spec_from_loader("rago_library", loader)
rl = importlib.util.module_from_spec(spec)
loader.exec_module(rl)

IS_ROOT = os.geteuid() == 0


def kernel_has(fs):
    def look():
        try:
            with open("/proc/filesystems") as f:
                return any(line.split()[-1] == fs for line in f if line.strip())
        except OSError:
            return False
    if look():
        return True
    if IS_ROOT and shutil.which("modprobe"):
        subprocess.run(["modprobe", fs], capture_output=True)
        return look()
    return False


COMM_FS = "vfat" if (IS_ROOT and shutil.which("mkfs.vfat") and kernel_has("vfat")) else "ext4"
MKNTFS = shutil.which("mkntfs") or shutil.which("mkfs.ntfs")
LIB_FS = "ntfs3" if (IS_ROOT and MKNTFS and kernel_has("ntfs3")) else "ext4"


# --- volumes NTFS fabriqués (structures publiques : layout.h de ntfs-3g) ----------------------

def protect(buf, usa_ofs, usa_count, usn=b"\x2a\x00"):
    """Pose les fixups comme Windows avant d'écrire un enregistrement."""
    b = bytearray(buf)
    struct.pack_into("<HH", b, 4, usa_ofs, usa_count)
    b[usa_ofs:usa_ofs + 2] = usn
    for i in range(1, usa_count):
        end = i * 512
        b[usa_ofs + 2 * i:usa_ofs + 2 * i + 2] = b[end - 2:end]
        b[end - 2:end] = usn
    return bytes(b)


def attr_resident(typ, value):
    hdr = 0x18
    length = (hdr + len(value) + 7) & ~7
    a = bytearray(length)
    struct.pack_into("<IIBBHHH", a, 0, typ, length, 0, 0, 0, 0, 0)
    struct.pack_into("<IH", a, 0x10, len(value), hdr)
    a[hdr:hdr + len(value)] = value
    return bytes(a)


def runlist_bytes(runs):
    out, prev = bytearray(), 0
    for length, lcn in runs:
        lb = length.to_bytes(4, "little")
        delta = lcn - prev
        ob = delta.to_bytes(4, "little", signed=True)
        out += bytes([0x44]) + lb + ob
        prev = lcn
    return bytes(out) + b"\0"


def attr_nonresident(typ, runs, cluster):
    mp = runlist_bytes(runs)
    hdr = 0x40
    length = (hdr + len(mp) + 7) & ~7
    a = bytearray(length)
    total = sum(r[0] for r in runs)
    struct.pack_into("<IIBBHHH", a, 0, typ, length, 1, 0, 0, 0, 0)
    struct.pack_into("<qq", a, 0x10, 0, total - 1)
    struct.pack_into("<H", a, 0x20, hdr)
    struct.pack_into("<qqq", a, 0x28, total * cluster, total * cluster, total * cluster)
    a[hdr:hdr + len(mp)] = mp
    return bytes(a)


def mft_record(attrs, in_use=True):
    r = bytearray(1024)
    r[0:4] = b"FILE"
    struct.pack_into("<H", r, 0x14, 0x38)
    struct.pack_into("<H", r, 0x16, 1 if in_use else 0)
    off = 0x38
    for a in attrs:
        r[off:off + len(a)] = a
        off += len(a)
    struct.pack_into("<I", r, off, 0xFFFFFFFF)
    struct.pack_into("<II", r, 0x18, off + 8, 1024)
    return protect(bytes(r), 0x30, 3)


def restart_page(version=(1, 1), in_use=0xFFFF, flags=0, lsn=100, magic=b"RSTR", page=4096):
    p = bytearray(page)
    p[0:4] = magic
    struct.pack_into("<QII", p, 8, 0, page, page)
    struct.pack_into("<Hhh", p, 0x18, 0x48, version[1], version[0])
    struct.pack_into("<QHHHH", p, 0x48, lsn, 1, 0xFFFF, in_use, flags)
    return protect(bytes(p), 0x28, page // 512 + 1)


CLUSTER = 4096
MFT_LCN = 4
LOG_LCN = 64
LOG_CLUSTERS = 16


def build_ntfs(path, *, log=None, dirty=False, label="RAGO-LIB", fragmented=False,
               size=4 * 1024 * 1024, declared=None, break_volume_fixup=False):
    """Petit volume NTFS : secteur de démarrage, MFT 0-3, $LogFile, $Volume."""
    img = bytearray(size)
    bs = bytearray(512)
    bs[0:3] = b"\xeb\x52\x90"
    bs[3:11] = b"NTFS    "
    struct.pack_into("<HB", bs, 0x0B, 512, 8)
    struct.pack_into("<QQQ", bs, 0x28, (declared or size) // 512 - 1, MFT_LCN, MFT_LCN + 1)
    struct.pack_into("<b", bs, 0x40, -10)
    struct.pack_into("<Q", bs, 0x48, 0x1122334455667788)
    bs[510:512] = b"\x55\xaa"
    img[0:512] = bs
    runs = [(1, LOG_LCN), (LOG_CLUSTERS - 1, LOG_LCN + 40)] if fragmented else [(LOG_CLUSTERS, LOG_LCN)]
    rec2 = mft_record([attr_nonresident(0x80, runs, CLUSTER)])
    vi = bytearray(12)
    vi[8], vi[9] = 3, 1
    struct.pack_into("<H", vi, 10, 1 if dirty else 0)
    rec3 = mft_record([attr_resident(0x60, label.encode("utf-16-le")), attr_resident(0x70, bytes(vi))])
    if break_volume_fixup:
        rec3 = bytearray(rec3)
        rec3[1022] ^= 0xFF
        rec3 = bytes(rec3)
    mft = MFT_LCN * CLUSTER
    for n, rec in ((0, mft_record([])), (1, mft_record([])), (2, rec2), (3, rec3)):
        img[mft + n * 1024:mft + (n + 1) * 1024] = rec
    logdata = bytearray(b"\xff" * (LOG_CLUSTERS * CLUSTER))
    for off, page in (log or []):
        logdata[off:off + len(page)] = page
    # Le journal suit ses plages (une seule, ou 1 cluster + le reste plus loin).
    pos = 0
    for length, lcn in runs:
        img[lcn * CLUSTER:(lcn + length) * CLUSTER] = logdata[pos:pos + length * CLUSTER]
        pos += length * CLUSTER
    with open(path, "wb") as f:
        f.write(img)


class NtfsCheck(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="rago-m7-ntfs-")
        self.img = os.path.join(self.d, "lib.img")

    def tearDown(self):
        shutil.rmtree(self.d)

    def inspect(self, **kw):
        build_ntfs(self.img, **kw)
        return rl.ntfs_inspect(self.img)

    def test_empty_log_is_clean(self):
        st = self.inspect()
        self.assertTrue(st["ntfs"])
        self.assertEqual(st["logfile"], "empty")
        self.assertEqual(st["label"], "RAGO-LIB")
        self.assertEqual(st["serial"], "1122334455667788")
        self.assertFalse(st["dirty"])
        self.assertTrue(st["rw_ok"], st["reasons"])

    def test_clean_v11_log(self):
        st = self.inspect(log=[(0, restart_page()), (4096, restart_page(lsn=90))])
        self.assertEqual((st["logfile"], st["logfile_version"]), ("clean", "1.1"))
        self.assertTrue(st["rw_ok"])

    def test_clean_flag_with_active_client(self):
        st = self.inspect(log=[(0, restart_page(in_use=0, flags=rl.RESTART_VOLUME_IS_CLEAN))])
        self.assertEqual(st["logfile"], "clean")

    def test_unclean_log(self):
        st = self.inspect(log=[(0, restart_page(in_use=0, flags=0))])
        self.assertEqual(st["logfile"], "unclean")
        self.assertFalse(st["rw_ok"])

    def test_windows_cache_v20_refused_even_if_clean(self):
        # Règle de ntfs-3g : la page la plus récente en 2.0 = métadonnées en cache.
        st = self.inspect(log=[(0, restart_page(version=(1, 1), lsn=10)),
                               (4096, restart_page(version=(2, 0), lsn=20))])
        self.assertEqual((st["logfile"], st["logfile_version"]), ("windows-cache", "2.0"))
        self.assertFalse(st["rw_ok"])
        self.assertIn("version 2.0", " ".join(st["reasons"]))

    def test_latest_page_wins(self):
        st = self.inspect(log=[(0, restart_page(version=(2, 0), lsn=10)),
                               (4096, restart_page(version=(1, 1), lsn=20))])
        self.assertEqual(st["logfile"], "clean")

    def test_chkdsk_page(self):
        st = self.inspect(log=[(0, restart_page(magic=b"CHKD"))])
        self.assertEqual(st["logfile"], "chkdsk")
        self.assertFalse(st["rw_ok"])

    def test_unknown_version(self):
        st = self.inspect(log=[(0, restart_page(version=(3, 0)))])
        self.assertEqual(st["logfile"], "unknown-version")
        self.assertFalse(st["rw_ok"])

    def test_second_copy_used_when_first_damaged(self):
        bad = bytearray(b"\x00" * 4096)
        st = self.inspect(log=[(0, bytes(bad)), (4096, restart_page(in_use=0))])
        self.assertEqual(st["logfile"], "unclean")

    def test_dirty_volume(self):
        st = self.inspect(dirty=True)
        self.assertTrue(st["dirty"])
        self.assertFalse(st["rw_ok"])
        self.assertIn("sale", " ".join(st["reasons"]))

    def test_fragmented_logfile(self):
        # Seconde page de redémarrage dans la seconde plage du journal.
        st = self.inspect(fragmented=True, log=[(0, restart_page(lsn=1)), (4096, restart_page(version=(2, 0), lsn=5))])
        self.assertEqual(st["logfile"], "windows-cache")

    def test_broken_fixup_is_doubt(self):
        st = self.inspect(break_volume_fixup=True)
        self.assertFalse(st["rw_ok"])
        self.assertIn("incohérent", " ".join(st["reasons"]))

    def test_torn_restart_page_is_doubt(self):
        page = bytearray(restart_page())
        page[2 * 512 - 1] ^= 0x55
        st = self.inspect(log=[(0, bytes(page))])
        self.assertFalse(st["rw_ok"])

    def test_volume_larger_than_device(self):
        st = self.inspect(declared=8 * 1024 * 1024)
        self.assertFalse(st["size_ok"])
        self.assertFalse(st["rw_ok"])

    def test_not_ntfs(self):
        with open(self.img, "wb") as f:
            f.write(b"\0" * 65536)
        st = rl.ntfs_inspect(self.img)
        self.assertFalse(st["ntfs"])
        self.assertFalse(st["rw_ok"])

    def test_missing_device(self):
        st = rl.ntfs_inspect(os.path.join(self.d, "absent"))
        self.assertFalse(st["rw_ok"])

    def test_cli_codes(self):
        build_ntfs(self.img)
        r = subprocess.run([sys.executable, "-I", HELPER, "ntfs-check", self.img], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        build_ntfs(self.img, dirty=True)
        r = subprocess.run([sys.executable, "-I", HELPER, "ntfs-check", self.img], capture_output=True, text=True)
        self.assertEqual(r.returncode, 3)
        with open(self.img, "wb") as f:
            f.write(b"\0" * 4096)
        r = subprocess.run([sys.executable, "-I", HELPER, "ntfs-check", self.img], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)


# --- règle de sûreté -----------------------------------------------------------------------------

def state(st="off", **lib):
    obj = {"schema": 1, "kind": "rago-library-windows-state", "state": st, "updated_at": "2026-11-14T10:00:00Z"}
    if lib:
        obj["lib"] = lib
    return json.dumps(obj).encode()


class Decide(unittest.TestCase):
    def test_off_and_offline_allows(self):
        ok, _ = rl.decide_from(state("off", found=True, offline=True), None)
        self.assertTrue(ok)

    def test_off_without_lib_found(self):
        self.assertTrue(rl.decide_from(state("off", found=False), None)[0])

    def test_doubts_are_read_only(self):
        for data in (None, b"{", b"[]", state("running", found=True, offline=False),
                     state("off", found=True, offline=False), state("off"), state("sleeping"),
                     json.dumps({"schema": 2, "kind": "rago-library-windows-state", "state": "off",
                                 "lib": {"offline": True}}).encode(),
                     json.dumps({"schema": 1, "kind": "autre", "state": "off", "lib": {"offline": True}}).encode()):
            ok, why = rl.decide_from(data, None)
            self.assertFalse(ok, (data, why))
            self.assertIn("lecture seule", why)

    def test_bom_accepted(self):
        self.assertTrue(rl.decide_from(b"\xef\xbb\xbf" + state("off", offline=True), None)[0])

    def test_confirm_only_for_the_state_seen(self):
        running = state("running", found=True, offline=False)
        confirm = {"kind": "rago-library-confirm-off", "windows_state_sha256": rl.state_digest(running)}
        self.assertTrue(rl.decide_from(running, confirm)[0])
        # Windows a redémarré depuis : nouvel état, la confirmation ne vaut plus.
        newer = state("running", found=True, offline=False).replace(b"10:00", b"11:00")
        self.assertFalse(rl.decide_from(newer, confirm)[0])
        absent = {"kind": "rago-library-confirm-off", "windows_state_sha256": "absent"}
        self.assertTrue(rl.decide_from(None, absent)[0])
        self.assertFalse(rl.decide_from(None, {"kind": "x", "windows_state_sha256": "absent"})[0])


class Requests(unittest.TestCase):
    def test_build(self):
        r = rl.build_request("install", "steam", "730", "Counter-Strike 2")
        self.assertEqual(r["id"], "install-steam-730")
        self.assertEqual(r["game_key"], "steam-730")
        self.assertEqual(r["kind"], "rago-library-request")
        self.assertEqual(r["name"], "Counter-Strike 2")
        e = rl.build_request("launch", "epic", "4fe75bbc5a674f4f9b356b5c90567da5:Fortnite:Fortnite")
        self.assertEqual(e["game_key"], "epic-fortnite")
        self.assertEqual(rl.build_request("install", "riot", "valorant")["id"], "install-riot-valorant")
        self.assertTrue(rl.REQ_ID_RE.fullmatch(e["id"]))

    def test_refused(self):
        for args in (("delete", "steam", "730"), ("install", "msstore", "x"), ("install", "gamepass", "x"),
                     ("install", "steam", "abc"), ("install", "steam", "1" * 11), ("install", "steam", ""),
                     ("install", "epic", "a/b"), ("install", "epic", "a:b"), ("install", "riot", "Valorant"),
                     ("install", "riot", "../x"), ("install", "steam", "730\n")):
            with self.assertRaises(rl.Refused, msg=args):
                rl.build_request(*args)
        with self.assertRaises(rl.Refused):
            rl.build_request("install", "steam", "730", "a\x1b[31m")
        with self.assertRaises(rl.Refused):
            rl.build_request("install", "steam", "730", "x" * 121)

    def test_request_ids(self):
        for bad in ("install-steam-", "x-steam-730", "install-steam-../a", "install-steam-730.json"):
            with self.assertRaises(rl.Refused):
                rl.check_req_id(bad)
        rl.check_req_id("launch-riot-league-of-legends")


class Games(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="rago-m7-games-")
        os.makedirs(os.path.join(self.d, ".rago", "games"))
        os.makedirs(os.path.join(self.d, "Games", "Steam", "steamapps", "common", "Counter-Strike Global Offensive"))

    def tearDown(self):
        shutil.rmtree(self.d)

    def put(self, name, obj):
        with open(os.path.join(self.d, ".rago", "games", name), "w", encoding="utf-8") as f:
            f.write("﻿" + json.dumps(obj))

    def test_read_games(self):
        self.put("steam-730.json", {"schema": 1, "kind": "rago-library-game", "key": "steam-730", "launcher": "steam",
                                    "launcher_id": "730", "name": "Counter-Strike 2", "installed": True,
                                    "install_dir": "Games/Steam/steamapps/common/Counter-Strike Global Offensive"})
        self.put("epic-x.json", {"schema": 1, "kind": "rago-library-game", "key": "epic-x", "installed": True,
                                 "install_dir": "..\\..\\etc"})
        self.put("riot-valorant.json", {"schema": 1, "kind": "rago-library-game", "key": "steam-1"})
        self.put("bad.json", {"kind": "rago-library-request"})
        with open(os.path.join(self.d, ".rago", "games", "junk.json"), "w") as f:
            f.write("{")
        games = {g.get("_file"): g for g in rl.read_games(self.d)}
        self.assertTrue(games["steam-730.json"]["install_dir_present"])
        self.assertFalse(games["epic-x.json"]["install_dir_present"])
        self.assertIn("_erreur", games["riot-valorant.json"])
        self.assertIn("_erreur", games["bad.json"])
        self.assertIn("_erreur", games["junk.json"])
        text = rl.text_list({"lib_dir": self.d, "lib_mode": "lecture seule", "library": None,
                             "games": rl.read_games(self.d), "comm_error": "absente"})
        self.assertIn("steam-730", text)
        self.assertIn("RAGO-COMM : absente", text)

    def test_install_dir_case_and_control_chars(self):
        # Le client écrit le nom de son manifeste ; ntfs3 respecte la casse, Windows non.
        self.put("steam-730.json", {"schema": 1, "kind": "rago-library-game", "key": "steam-730", "launcher": "steam",
                                    "launcher_id": "730", "name": "CS\x1b[2J\x9b2", "installed": True,
                                    "install_dir": "games\\steam\\STEAMAPPS\\common\\counter-strike global offensive"})
        games = rl.read_games(self.d)
        self.assertTrue(games[0]["install_dir_present"])
        self.assertFalse(rl.isdir_nocase(self.d, "Games/Steam/steamapps/common/absent"))
        text = rl.text_list({"lib_dir": self.d, "lib_mode": "lecture seule", "library": None,
                             "games": games, "comm_error": "absente"})
        self.assertNotIn("\x1b", text)
        self.assertNotIn("\x9b", text)
        self.assertIn("CS[2J2", text)

    def test_init_needs_write(self):
        with self.assertRaises(rl.Failed):
            rl.cmd_init(os.path.join(self.d, "absent"))
        rl.cmd_init(self.d)
        lib = rl.read_json(os.path.join(self.d, ".rago", "library.json"))
        self.assertEqual(lib["kind"], "rago-library")
        for sub in (".rago/cache", "Games/Steam", "Games/Epic", "Games/Riot"):
            self.assertTrue(os.path.isdir(os.path.join(self.d, sub)), sub)


class Conf(unittest.TestCase):
    def test_bash_conf_rules(self):
        d = tempfile.mkdtemp(prefix="rago-m7-conf-")
        try:
            def run_with(text, mode=0o644):
                p = os.path.join(d, "lib.conf")
                with open(p, "w") as f:
                    f.write(text)
                os.chmod(p, mode)
                return subprocess.run(["bash", SCRIPT, "--help"], capture_output=True, text=True,
                                      env={"PATH": os.environ["PATH"], "RAGO_LIBRARY_CONF": p})
            self.assertEqual(run_with("RAGO_LIB_DIR=/run/rago/lib\n").returncode, 0)
            for bad in ("RAGO_LIB_OPTIONS=uid=0,force\n", "RAGO_LIB_OPTIONS=rw\n", "RAGO_LIB_FSTYPE=ntfs\n",
                        "RAGO_LIB_FSTYPE=fuseblk\n", "RAGO_LIB_DIR=relatif\n", "RAGO_LIB_DIR=/\n",
                        "AUTRE=1\n", "pas de egal\n", "RAGO_LIB_REQUIRE_NTFS=2\n"):
                r = run_with(bad)
                self.assertNotEqual(r.returncode, 0, bad)
            self.assertNotEqual(run_with("RAGO_LIB_DIR=/run/rago/lib\n", 0o666).returncode, 0)
            # Tests seulement : un autre système de fichiers si RAGO_LIB_REQUIRE_NTFS=0.
            self.assertEqual(run_with("RAGO_LIB_REQUIRE_NTFS=0\nRAGO_LIB_FSTYPE=ext4\n").returncode, 0)
        finally:
            shutil.rmtree(d)

    def test_repo_conf_matches_script_defaults(self):
        conf = {}
        with open(os.path.join(REPO, "host", "rago-library.conf"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    conf[k] = v
        with open(SCRIPT, encoding="utf-8") as f:
            script = f.read()
        for k, v in conf.items():
            self.assertIn(f"{k}={v}\n", script, k)
        self.assertNotIn("force", conf["RAGO_LIB_OPTIONS"].split(","))
        self.assertEqual(conf["RAGO_LIB_FSTYPE"], "ntfs3")

    def test_never_ntfs3g_never_force(self):
        with open(SCRIPT, encoding="utf-8") as f:
            code = "\n".join(line for line in f if not line.lstrip().startswith("#"))
        for bad in ("-t ntfs-3g", "-t ntfs ", "mount.ntfs", "ntfsfix", "ntfs-3g -o", "lowntfs"):
            self.assertNotIn(bad, code)
        self.assertIn('mount -i -t "$RAGO_LIB_FSTYPE"', code)
        self.assertNotRegex(code, r"-o[^\n]*\bforce\b")

    def test_guard_unit(self):
        with open(os.path.join(REPO, "host", "systemd", "rago-library-sleep-guard.service"), encoding="utf-8") as f:
            unit = f.read()
        for u in ("systemd-hibernate.service", "systemd-hybrid-sleep.service", "systemd-suspend-then-hibernate.service"):
            self.assertRegex(unit, rf"RequiredBy=.*{u}")
            self.assertRegex(unit, rf"Before=.*{u}")
        self.assertIn("DefaultDependencies=no", unit)
        self.assertIn("ExecStart=/usr/lib/rago/rago-library.sh __sleep-guard", unit)
        self.assertNotIn("systemd-suspend.service", unit.split("[Install]")[1])
        self.assertNotIn("rago-comm", unit.split("[Unit]")[1].lower().split("[service]")[0].replace("rago-comm (", ""))


# --- vrais montages (root) -----------------------------------------------------------------------

def sh(*cmd, check=True):
    return subprocess.run(list(cmd), capture_output=True, text=True, check=check)


@unittest.skipUnless(IS_ROOT and shutil.which("losetup") and kernel_has(LIB_FS),
                     "root, losetup et un système de fichiers montable requis")
class RealLibrary(unittest.TestCase):
    """RAGO-COMM (image, faux systemctl) + RAGO-LIB (loop) + rago-library.sh de bout en bout."""

    @classmethod
    def setUpClass(cls):
        cls.d = tempfile.mkdtemp(prefix="rago-m7-")
        cls.comm_img = os.path.join(cls.d, "comm.img")
        with open(cls.comm_img, "wb") as f:
            f.truncate(64 * 1024 * 1024)
        if COMM_FS == "vfat":
            sh("mkfs.vfat", "-F", "32", "-n", "RAGO-COMM", cls.comm_img)
        else:
            sh("mkfs.ext4", "-q", "-F", "-L", "RAGO-COMM", cls.comm_img)
        cls.comm_dev = os.path.join(cls.d, "by-label-RAGO-COMM")
        os.symlink(cls.comm_img, cls.comm_dev)
        cls.comm_mnt = os.path.join(cls.d, "comm")
        os.makedirs(cls.comm_mnt)
        cls.lib_img = os.path.join(cls.d, "lib.img")
        cls.lib_dev = None
        cls.lib_mnt = os.path.join(cls.d, "lib")
        cls.make_lib()

    @classmethod
    def make_lib(cls):
        if cls.lib_dev:
            sh("losetup", "-d", cls.lib_dev, check=False)
        with open(cls.lib_img, "wb") as f:
            f.truncate(0)
            f.truncate(256 * 1024 * 1024)
        if LIB_FS == "ntfs3":
            sh(MKNTFS, "-F", "-Q", "-L", "RAGO-LIB", cls.lib_img)
        else:
            sh("mkfs.ext4", "-q", "-F", "-L", "RAGO-LIB", cls.lib_img)
        cls.lib_dev = sh("losetup", "-f", "--show", cls.lib_img).stdout.strip()

    @classmethod
    def tearDownClass(cls):
        for m in (cls.lib_mnt, cls.comm_mnt):
            subprocess.run(["umount", m], capture_output=True)
        if cls.lib_dev:
            subprocess.run(["losetup", "-d", cls.lib_dev], capture_output=True)
        shutil.rmtree(cls.d)

    def setUp(self):
        for m in (self.lib_mnt, self.comm_mnt):
            subprocess.run(["umount", m], capture_output=True)
        self.fake = os.path.join(self.d, "systemctl")
        opts = ("rw,nosuid,nodev,noexec,noatime,uid=0,gid=0,fmask=0177,dmask=0077,utf8,shortname=mixed,flush"
                if COMM_FS == "vfat" else "rw,nosuid,nodev,noexec,noatime")
        with open(self.fake, "w") as f:
            f.write(f"""#!/bin/sh
case "$2" in
start) mount -o loop,{opts} -t {COMM_FS} {self.comm_img} {self.comm_mnt} ;;
stop) umount {self.comm_mnt} ;;
*) exit 9 ;;
esac
""")
        os.chmod(self.fake, 0o755)
        self.comm_conf = os.path.join(self.d, "rago-comm.conf")
        with open(self.comm_conf, "w") as f:
            f.write(f"RAGO_COMM_DIR={self.comm_mnt}\nRAGO_COMM_DEVICE={self.comm_dev}\nRAGO_COMM_SYSTEMCTL={self.fake}\n")
            if COMM_FS != "vfat":
                f.write("RAGO_COMM_REQUIRE_VFAT=0\n")
        os.chmod(self.comm_conf, 0o644)
        self.lib_conf = os.path.join(self.d, "rago-library.conf")
        with open(self.lib_conf, "w") as f:
            f.write(f"RAGO_LIB_DEVICE={self.lib_dev}\nRAGO_LIB_DIR={self.lib_mnt}\n")
            if LIB_FS != "ntfs3":
                f.write("RAGO_LIB_FSTYPE=ext4\nRAGO_LIB_REQUIRE_NTFS=0\nRAGO_LIB_OPTIONS=nosuid,nodev,noexec,noatime\n")
        os.chmod(self.lib_conf, 0o644)
        self.windows_state(None)
        self.comm_rm("library/linux-confirm.json")

    def tearDown(self):
        subprocess.run(["umount", self.lib_mnt], capture_output=True)

    def lib(self, *args, stdin=None):
        env = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8",
               "RAGO_LIBRARY_CONF": self.lib_conf, "RAGO_COMM_CONF": self.comm_conf}
        return subprocess.run(["bash", SCRIPT] + list(args), capture_output=True, text=True, env=env,
                              input=stdin, timeout=120)

    # Écrit ou lit RAGO-COMM « comme Windows » (montage direct, hors rago-library).
    def comm_open(self):
        sh(self.fake, "--quiet", "start", "x")

    def comm_close(self):
        sh(self.fake, "--quiet", "stop", "x")

    def comm_rm(self, rel):
        self.comm_open()
        try:
            p = os.path.join(self.comm_mnt, rel)
            if os.path.exists(p):
                os.remove(p)
        finally:
            self.comm_close()

    def comm_read(self, rel):
        self.comm_open()
        try:
            return rl.read_json(os.path.join(self.comm_mnt, rel))
        finally:
            self.comm_close()

    def comm_list(self, rel):
        self.comm_open()
        try:
            p = os.path.join(self.comm_mnt, rel)
            return sorted(os.listdir(p)) if os.path.isdir(p) else []
        finally:
            self.comm_close()

    def windows_state(self, st, offline=True, updated="2026-11-14T10:00:00Z"):
        self.comm_open()
        try:
            p = os.path.join(self.comm_mnt, "library", "windows-state.json")
            if st is None:
                if os.path.exists(p):
                    os.remove(p)
            else:
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "w", encoding="utf-8-sig") as f:  # BOM : Windows PowerShell 5.1
                    json.dump({"schema": 1, "kind": "rago-library-windows-state", "state": st,
                               "updated_at": updated, "boot_id": "2026-11-14T09:58:00Z",
                               "lib": {"found": True, "offline": offline}}, f)
        finally:
            self.comm_close()

    def mode(self):
        r = subprocess.run(["findmnt", "-rn", "-M", self.lib_mnt, "-o", "OPTIONS,FSTYPE"], capture_output=True, text=True)
        if r.returncode != 0 or not r.stdout.strip():
            return None
        opts, fstype = r.stdout.split()
        self.assertEqual(fstype, LIB_FS)
        return "rw" if "rw" in opts.split(",") else "ro"

    def comm_mounted(self):
        return rl.mount_info(self.comm_mnt) is not None

    def test_no_windows_state_mounts_read_only(self):
        r = self.lib("mount")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertEqual(self.mode(), "ro")
        self.assertIn("jamais écrit son état", r.stderr)
        self.assertFalse(self.comm_mounted(), "RAGO-COMM doit être démontée")

    def test_rw_refused_mounts_nothing(self):
        self.windows_state("running", offline=False)
        r = self.lib("mount", "--rw")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIsNone(self.mode())
        self.assertIn("pas fini proprement", r.stderr)

    def test_windows_off_allows_write_and_init(self):
        self.windows_state("off")
        r = self.lib("mount")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.mode(), "rw")
        self.assertTrue(os.path.isfile(os.path.join(self.lib_mnt, ".rago", "library.json")))
        self.assertTrue(os.path.isdir(os.path.join(self.lib_mnt, "Games", "Steam")))
        # Déjà monté en écriture : rien à faire.
        self.assertEqual(self.lib("mount").returncode, 0)
        self.assertEqual(self.lib("umount").returncode, 0)
        self.assertIsNone(self.mode())

    def test_running_then_confirm_off(self):
        self.windows_state("running", offline=False)
        self.assertEqual(self.lib("mount").returncode, 3)
        self.assertEqual(self.mode(), "ro")
        r = self.lib("confirm-windows-off", stdin="non\n")
        self.assertEqual(r.returncode, 2)
        r = self.lib("confirm-windows-off", stdin="oui\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        # Monté en lecture seule : la remonte en écriture.
        r = self.lib("mount")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.mode(), "rw")
        self.lib("umount")
        # Windows redémarre et écrit un nouvel état : la confirmation ne vaut plus.
        self.windows_state("running", offline=False, updated="2026-11-14T12:00:00Z")
        self.assertEqual(self.lib("mount", "--rw").returncode, 3)

    def test_ro_requested(self):
        self.windows_state("off")
        r = self.lib("mount", "--ro")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.mode(), "ro")

    def test_requests_and_status(self):
        r = self.lib("install", "steam", "730", "--name", "Counter-Strike 2")
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.lib("launch", "riot", "valorant")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.lib("install", "gamepass", "x").returncode, 2)
        self.assertEqual(self.lib("install", "steam", "73a").returncode, 2)
        self.assertEqual(self.comm_list("library/requests"), ["install-steam-730.json", "launch-riot-valorant.json"])
        req = self.comm_read("library/requests/install-steam-730.json")
        self.assertEqual((req["launcher"], req["launcher_id"], req["name"]), ("steam", "730", "Counter-Strike 2"))
        r = self.lib("status")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("install-steam-730", r.stdout)
        self.assertIn("lecture seule", r.stdout)
        st = json.loads(self.lib("status", "--json").stdout)
        self.assertEqual(len(st["requests"]), 2)
        self.assertEqual(self.lib("cancel", "launch-riot-valorant").returncode, 0)
        self.assertEqual(self.lib("cancel", "launch-riot-valorant").returncode, 1)
        self.assertEqual(self.lib("cancel", "../../etc/passwd").returncode, 2)
        self.assertEqual(self.comm_list("library/requests"), ["install-steam-730.json"])
        # Résultat écrit par Windows : « forget » seulement quand c'est fini.
        self.comm_open()
        try:
            res = os.path.join(self.comm_mnt, "library", "results")
            os.makedirs(res, exist_ok=True)
            with open(os.path.join(res, "install-steam-730.json"), "w", encoding="utf-8-sig") as f:
                json.dump({"schema": 1, "kind": "rago-library-result", "id": "install-steam-730",
                           "state": "running", "updated_at": "2026-11-14T10:05:00Z", "message": "Steam télécharge"}, f)
        finally:
            self.comm_close()
        self.assertIn("en cours", self.lib("status").stdout)
        self.assertEqual(self.lib("forget", "install-steam-730").returncode, 2)
        self.assertFalse(self.comm_mounted())

    def test_list_mounts_read_only_temporarily(self):
        self.windows_state("off")
        self.assertEqual(self.lib("mount", "--rw").returncode, 0)
        g = os.path.join(self.lib_mnt, ".rago", "games", "steam-730.json")
        with open(g, "w") as f:
            json.dump({"schema": 1, "kind": "rago-library-game", "key": "steam-730", "launcher": "steam",
                       "launcher_id": "730", "name": "Counter-Strike 2", "installed": True,
                       "install_dir": "Games/Steam"}, f)
        self.lib("umount")
        r = self.lib("list")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("steam-730", r.stdout)
        self.assertIn("Counter-Strike 2", r.stdout)
        self.assertIsNone(self.mode(), "list doit démonter ce qu'il a monté")
        data = json.loads(self.lib("list", "--json").stdout)
        self.assertEqual(data["games"][0]["key"], "steam-730")
        self.assertTrue(data["games"][0]["install_dir_present"])

    def test_sleep_guard(self):
        self.assertEqual(self.lib("__sleep-guard").returncode, 0)
        self.lib("mount", "--ro")
        r = self.lib("__sleep-guard")
        self.assertEqual(r.returncode, 1)
        self.assertIn("hibernation REFUSÉE", r.stderr)
        self.lib("umount")
        self.assertEqual(self.lib("__sleep-guard").returncode, 0)
        self.assertFalse(self.comm_mounted(), "le garde ne doit jamais monter RAGO-COMM")

    def test_busy_umount_reports(self):
        self.windows_state("off")
        self.lib("mount")
        p = subprocess.Popen(["sleep", "30"], cwd=self.lib_mnt)
        try:
            r = self.lib("umount")
            self.assertEqual(r.returncode, 1)
            self.assertIn("occupée", r.stderr)
        finally:
            p.kill()
            p.wait()
        self.assertEqual(self.lib("umount").returncode, 0)

    def test_already_mounted_elsewhere_refused(self):
        other = os.path.join(self.d, "ailleurs")
        os.makedirs(other, exist_ok=True)
        sh("mount", "-o", "ro", "-t", LIB_FS, self.lib_dev, other)
        try:
            r = self.lib("mount", "--ro")
            self.assertEqual(r.returncode, 1)
            self.assertIn("déjà montée", r.stderr)
        finally:
            sh("umount", other)

    def test_comm_missing(self):
        with open(self.comm_conf, "a") as f:
            f.write(f"RAGO_COMM_DEVICE={self.d}/absent\n")
        self.windows_state(None)
        r = self.lib("mount")
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertEqual(self.mode(), "ro")
        self.assertIn("RAGO-COMM inaccessible", r.stderr)
        self.assertEqual(self.lib("install", "steam", "730").returncode, 1)

    @unittest.skipUnless(LIB_FS == "ntfs3", "vrai NTFS + ntfs3 seulement (VM)")
    def test_ntfs_dirty_refused_by_us_and_by_ntfs3(self):
        """Le bit « sale » posé par nous est vu par ntfs3 aussi : preuve que le contrôle lit le bon octet."""
        self.windows_state("off")
        st = rl.ntfs_inspect(self.lib_dev)
        self.assertEqual(st["logfile"], "empty", st)
        self.assertTrue(st["rw_ok"], st)
        set_dirty(self.lib_dev, True)
        try:
            self.assertTrue(rl.ntfs_inspect(self.lib_dev)["dirty"])
            r = self.lib("mount", "--rw")
            self.assertEqual(r.returncode, 3)
            self.assertIn("sale", r.stderr)
            os.makedirs(os.path.join(self.d, "x"), exist_ok=True)
            k = subprocess.run(["mount", "-i", "-t", "ntfs3", "-o", "rw", self.lib_dev, os.path.join(self.d, "x")],
                               capture_output=True, text=True)
            if k.returncode == 0:
                subprocess.run(["umount", os.path.join(self.d, "x")])
            self.assertNotEqual(k.returncode, 0, "ntfs3 doit refuser lui aussi un volume sale sans « force »")
        finally:
            set_dirty(self.lib_dev, False)
        self.assertEqual(self.lib("mount", "--rw").returncode, 0)
        with open(os.path.join(self.lib_mnt, "écrit par Linux.txt"), "w") as f:
            f.write("ntfs3\n")
        self.assertEqual(self.lib("umount").returncode, 0)
        # Après un montage en écriture et un démontage propre par ntfs3 : toujours propre.
        st = rl.ntfs_inspect(self.lib_dev)
        self.assertTrue(st["rw_ok"], st)
        self.assertFalse(st["dirty"])

    @unittest.skipUnless(LIB_FS == "ntfs3" and shutil.which("ntfscat"), "vrai NTFS + ntfscat (VM)")
    def test_ntfs_windows_cache_log(self):
        """Page de redémarrage 2.0 posée au début de $LogFile, trouvé par notre lecture ; ntfscat confirme l'endroit."""
        self.windows_state("off")
        put_log_page(self.lib_dev, restart_page(version=(2, 0), in_use=0, lsn=50))
        try:
            head = subprocess.run(["ntfscat", "-i", "2", self.lib_dev], capture_output=True).stdout[:4]
            self.assertEqual(head, b"RSTR", "ntfscat doit lire la page posée au début de $LogFile")
            st = rl.ntfs_inspect(self.lib_dev)
            self.assertEqual(st["logfile"], "windows-cache", st)
            r = self.lib("mount")
            self.assertEqual(r.returncode, 3)
            self.assertEqual(self.mode(), "ro")
            self.assertIn("version 2.0", r.stderr)
        finally:
            self.lib("umount")
            self.make_lib()


def set_dirty(dev, on):
    """Pose / enlève VOLUME_IS_DIRTY dans $Volume (enregistrement 3), fixups compris."""
    fd = os.open(dev, os.O_RDWR)
    try:
        v = rl.Ntfs(fd)
        off = v.mft_lcn * v.cluster + 3 * v.rec_size
        raw = bytearray(os.pread(fd, v.rec_size, off))
        rec = bytearray(rl.mst_fixup(bytes(raw), "test"))
        a_off, = struct.unpack_from("<H", rec, 0x14)
        while True:
            typ, length = struct.unpack_from("<II", rec, a_off)
            if typ == 0x70:
                voff, = struct.unpack_from("<H", rec, a_off + 0x14)
                flags, = struct.unpack_from("<H", rec, a_off + voff + 10)
                flags = (flags | 1) if on else (flags & ~1)
                struct.pack_into("<H", rec, a_off + voff + 10, flags)
                break
            if typ == 0xFFFFFFFF:
                raise AssertionError("$VOLUME_INFORMATION absent")
            a_off += length
        usa_ofs, usa_count = struct.unpack_from("<HH", rec, 4)
        os.pwrite(fd, protect(bytes(rec), usa_ofs, usa_count, usn=bytes(raw[usa_ofs:usa_ofs + 2])), off)
        os.fsync(fd)
    finally:
        os.close(fd)


def put_log_page(dev, page):
    fd = os.open(dev, os.O_RDWR)
    try:
        v = rl.Ntfs(fd)
        data = None
        for typ, a in v.attrs(v.record(2), 2):
            if typ == 0x80 and a[9] == 0:
                data = a
        runs, _ = rl.runlist(data, "$LogFile")
        os.pwrite(fd, page, runs[0][2] * v.cluster)
        os.fsync(fd)
    finally:
        os.close(fd)


if __name__ == "__main__":
    print(f"RAGO-COMM : {COMM_FS} ; RAGO-LIB : {LIB_FS}" + ("" if IS_ROOT else " (sans root : tests de montage sautés)"),
          file=sys.stderr)
    unittest.main()
