#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tests du hook host/hooks/windows-security (module M5).
#
# Sans root : règles d'entrée (valeurs, profil incohérent), réglages, codes de
# sortie. En root (conteneur jetable) en plus : vraie partition FAT32 sur un
# fichier image (mkfs.vfat + loop), montée par un faux systemctl qui imite
# run-rago-comm.mount (start = mount, stop = umount), puis bout en bout avec le
# vrai rago-profiled (prepare-switch → hook → RAGO-COMM).
#
# Usage : python3 host/tests/test_windows_security_hook.py [-v]
#         RAGO_PROFILED_BIN=target/release/rago-profiled (défaut si présent)
import importlib.machinery
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
HOOK = os.path.join(REPO, "host", "hooks", "windows-security")
loader = importlib.machinery.SourceFileLoader("winsec", HOOK)
spec = importlib.util.spec_from_loader("winsec", loader)
ws = importlib.util.module_from_spec(spec)
loader.exec_module(ws)

IS_ROOT = os.geteuid() == 0


def kernel_has(fs):
    try:
        with open("/proc/filesystems") as f:
            if any(line.split()[-1] == fs for line in f if line.strip()):
                return True
    except OSError:
        return False
    if IS_ROOT and shutil.which("modprobe"):
        subprocess.run(["modprobe", fs], capture_output=True)
        with open("/proc/filesystems") as f:
            return any(line.split()[-1] == fs for line in f if line.strip())
    return False


# Vraie FAT32 si le noyau la connaît (VM de test) ; sinon (noyau du conteneur
# sans vfat) image ext4 et RAGO_COMM_REQUIRE_VFAT=0 : la logique de montage,
# d'écriture et de démontage est la même, seul le type de système change.
FS = "vfat" if (shutil.which("mkfs.vfat") and kernel_has("vfat")) else "ext4"
PROFILED = os.environ.get("RAGO_PROFILED_BIN", os.path.join(REPO, "target", "release", "rago-profiled"))

FORTNITE = {"id": "fortnite", "name": "Fortnite", "couche": "switch", "windows_security": "perf",
            "source": "/usr/share/rago/profiles/fortnite.json", "verified": False}


def env_for(value="perf", pid="fortnite", **extra):
    e = {"RAGO_WINDOWS_SECURITY": value, "RAGO_PROFILE_ID": pid}
    e.update(extra)
    return e


def run_hook(args, env, stdin=""):
    full = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"}
    full.update(env)
    return subprocess.run([sys.executable, "-I", HOOK] + args, input=stdin, capture_output=True,
                          text=True, env=full, timeout=60)


class RequestRules(unittest.TestCase):
    def test_valid_values(self):
        for v in ("compat_max", "perf"):
            r = ws.parse_request(env_for(v), json.dumps(dict(FORTNITE, windows_security=v)))
            self.assertEqual(r["security"], v)
            self.assertEqual(r["profile_id"], "fortnite")
            self.assertEqual(r["schema"], 1)
            self.assertEqual(r["kind"], "rago-windows-security")
            self.assertEqual(r["profile"]["name"], "Fortnite")
            self.assertRegex(r["written_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")

    def test_fallback_profile_id(self):
        r = ws.parse_request(env_for("compat_max", "_fallback"),
                             json.dumps({"id": "_fallback", "couche": "switch", "windows_security": "compat_max"}))
        self.assertEqual(r["profile_id"], "_fallback")

    def test_empty_stdin_is_allowed(self):
        self.assertEqual(ws.parse_request(env_for("compat_max", "valorant"), "")["profile"], {})

    def test_refused(self):
        cases = [
            (env_for("off"), json.dumps(FORTNITE), "RAGO_WINDOWS_SECURITY"),
            (env_for(""), json.dumps(FORTNITE), "RAGO_WINDOWS_SECURITY"),
            (env_for("COMPAT_MAX"), "{}", "RAGO_WINDOWS_SECURITY"),
            (env_for("perf", "Fortnite"), "{}", "RAGO_PROFILE_ID"),
            (env_for("perf", "../x"), "{}", "RAGO_PROFILE_ID"),
            (env_for("perf", ""), "{}", "RAGO_PROFILE_ID"),
            (env_for("perf", "x" * 65), "{}", "RAGO_PROFILE_ID"),
            (env_for("perf"), json.dumps(dict(FORTNITE, id="valorant")), "incohérent"),
            (env_for("perf"), json.dumps(dict(FORTNITE, windows_security="compat_max")), "incohérent"),
            (env_for("perf"), json.dumps(dict(FORTNITE, couche="proton")), "couche"),
            (env_for("perf"), "[1, 2]", "objet"),
            (env_for("perf"), "{pas du json", "illisible"),
            (env_for("perf"), json.dumps({"x": "a" * (70 * 1024)}), "trop gros"),
        ]
        for env, stdin, word in cases:
            with self.subTest(env=env, stdin=stdin[:40]):
                with self.assertRaises(ws.Refused) as cm:
                    ws.parse_request(env, stdin)
                self.assertIn(word, str(cm.exception))


class Conf(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.d)

    def write(self, text, mode=0o644):
        p = os.path.join(self.d, "rago-comm.conf")
        with open(p, "w") as f:
            f.write(text)
        os.chmod(p, mode)
        return p

    def test_missing_file_gives_defaults(self):
        c = ws.load_conf(os.path.join(self.d, "absent"))
        self.assertEqual(c["RAGO_COMM_DIR"], "/run/rago/comm")
        self.assertEqual(c["RAGO_COMM_MOUNT"], "systemd")
        self.assertEqual(c["RAGO_COMM_UNIT"], "run-rago-comm.mount")

    def test_repo_conf_is_the_default(self):
        c = ws.load_conf(os.path.join(REPO, "host", "rago-comm.conf"))
        self.assertEqual(c, ws.DEFAULTS)

    def test_parse_and_quotes(self):
        c = ws.load_conf(self.write('# commentaire\n\nRAGO_COMM_DIR="/mnt/x"\nRAGO_COMM_MOUNT=none\n'))
        self.assertEqual(c["RAGO_COMM_DIR"], "/mnt/x")
        self.assertEqual(c["RAGO_COMM_MOUNT"], "none")

    def test_bad_conf(self):
        for text, word in [("RAGO_COMM_FOO=1\n", "inconnu"), ("pas de egal\n", "sans"),
                           ("RAGO_COMM_MOUNT=auto\n", "systemd ou none"), ("RAGO_COMM_DIR=relatif\n", "absolu")]:
            with self.subTest(text=text):
                with self.assertRaises(ws.Failed) as cm:
                    ws.load_conf(self.write(text))
                self.assertIn(word, str(cm.exception))

    def test_group_writable_conf_refused(self):
        with self.assertRaises(ws.Failed):
            ws.load_conf(self.write("RAGO_COMM_MOUNT=none\n", 0o664))


class ExitCodes(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.conf = os.path.join(self.d, "conf")
        with open(self.conf, "w") as f:
            f.write(f"RAGO_COMM_DIR={self.d}/pas-monte\nRAGO_COMM_MOUNT=none\n")

    def tearDown(self):
        shutil.rmtree(self.d)

    def test_usage(self):
        self.assertEqual(run_hook(["--help"], {}).returncode, 0)
        self.assertEqual(run_hook([], {}).returncode, 2)
        self.assertEqual(run_hook(["apply"], {"RAGO_COMM_CONF": self.conf}).returncode, 2)

    def test_refused_is_2_and_nothing_mounted(self):
        r = run_hook(["set"], env_for("off", RAGO_COMM_CONF=self.conf), "{}")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("refusé", r.stderr)

    def test_not_mounted_is_1(self):
        r = run_hook(["set"], env_for(RAGO_COMM_CONF=self.conf), json.dumps(FORTNITE))
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("pas montée", r.stderr)

    def test_device_missing_is_1_without_systemctl(self):
        conf = os.path.join(self.d, "conf2")
        log = os.path.join(self.d, "systemctl.log")
        fake = os.path.join(self.d, "systemctl")
        with open(fake, "w") as f:
            f.write(f"#!/bin/sh\necho \"$@\" >> {log}\n")
        os.chmod(fake, 0o755)
        with open(conf, "w") as f:
            f.write(f"RAGO_COMM_DIR={self.d}/m\nRAGO_COMM_DEVICE={self.d}/absent\nRAGO_COMM_SYSTEMCTL={fake}\n")
        r = run_hook(["set"], env_for(RAGO_COMM_CONF=conf), json.dumps(FORTNITE))
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("introuvable", r.stderr)
        self.assertFalse(os.path.exists(log), "systemctl ne doit pas être appelé sans partition")


@unittest.skipUnless(IS_ROOT, "root nécessaire (vrai montage sur loop)")
class RealMount(unittest.TestCase):
    """Vraie partition (FAT32 si possible) sur fichier image + loop, faux systemctl qui monte."""

    @classmethod
    def setUpClass(cls):
        cls.d = tempfile.mkdtemp(prefix="rago-m5-")
        cls.img = os.path.join(cls.d, "comm.img")
        with open(cls.img, "wb") as f:
            f.truncate(64 * 1024 * 1024)
        if FS == "vfat":
            subprocess.run(["mkfs.vfat", "-F", "32", "-n", "RAGO-COMM", cls.img], check=True, capture_output=True)
        else:
            subprocess.run(["mkfs.ext4", "-q", "-F", "-L", "RAGO-COMM", cls.img], check=True, capture_output=True)
        # Faux « périphérique » : le hook vérifie seulement qu'il existe.
        cls.dev = os.path.join(cls.d, "by-label-RAGO-COMM")
        os.symlink(cls.img, cls.dev)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["umount", os.path.join(cls.d, "mnt")], capture_output=True)
        shutil.rmtree(cls.d)

    def setUp(self):
        self.mnt = os.path.join(self.d, "mnt")
        os.makedirs(self.mnt, exist_ok=True)
        self.log = os.path.join(self.d, "systemctl.log")
        if os.path.exists(self.log):
            os.remove(self.log)
        self.fake = os.path.join(self.d, "systemctl")
        # Même options que host/systemd/run-rago-comm.mount.
        if FS == "vfat":
            opts = "rw,nosuid,nodev,noexec,noatime,uid=0,gid=0,fmask=0177,dmask=0077,utf8,shortname=mixed,errors=remount-ro,flush"
        else:
            opts = "rw,nosuid,nodev,noexec,noatime"
        with open(self.fake, "w") as f:
            f.write(f"""#!/bin/sh
echo "$*" >> {self.log}
case "$2" in
start) mount -o loop,{opts} -t {FS} {self.img} {self.mnt} ;;
stop) umount {self.mnt} ;;
*) exit 9 ;;
esac
""")
        os.chmod(self.fake, 0o755)
        self.conf = os.path.join(self.d, "rago-comm.conf")
        with open(self.conf, "w") as f:
            f.write(f"RAGO_COMM_DIR={self.mnt}\nRAGO_COMM_DEVICE={self.dev}\nRAGO_COMM_SYSTEMCTL={self.fake}\n")
            if FS != "vfat":
                f.write("RAGO_COMM_REQUIRE_VFAT=0\n")
        os.chmod(self.conf, 0o644)

    def tearDown(self):
        subprocess.run(["umount", self.mnt], capture_output=True)

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return [line.split() for line in f.read().splitlines()]

    def mounted(self):
        return ws.mount_info(self.mnt) is not None

    def read_from_image(self, path):
        """Lit un fichier de l'image après le démontage : mtools pour la FAT (comme
        un autre OS, sans le pilote vfat de Linux), montage en lecture seule sinon."""
        if FS == "vfat" and shutil.which("mtype"):
            r = subprocess.run(["mtype", "-i", self.img, "::" + path], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout
        ro = os.path.join(self.d, "ro")
        os.makedirs(ro, exist_ok=True)
        subprocess.run(["mount", "-o", "loop,ro", "-t", FS, self.img, ro], check=True)
        try:
            with open(ro + path, encoding="utf-8") as f:
                return f.read()
        finally:
            subprocess.run(["umount", ro], check=True)

    def list_dir(self, path):
        if FS == "vfat" and shutil.which("mdir"):
            return subprocess.run(["mdir", "-b", "-i", self.img, "::" + path], capture_output=True, text=True).stdout
        ro = os.path.join(self.d, "ro")
        os.makedirs(ro, exist_ok=True)
        subprocess.run(["mount", "-o", "loop,ro", "-t", FS, self.img, ro], check=True)
        try:
            return "\n".join(os.listdir(ro + path))
        finally:
            subprocess.run(["umount", ro], check=True)

    def test_set_mounts_writes_and_unmounts(self):
        r = run_hook(["set"], env_for(RAGO_COMM_CONF=self.conf), json.dumps(FORTNITE))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip().splitlines()[-1],
                         "perf écrit dans RAGO-COMM (security/profile.json, profil fortnite)")
        self.assertEqual(self.calls(), [["--quiet", "start", "run-rago-comm.mount"],
                                        ["--quiet", "stop", "run-rago-comm.mount"]])
        self.assertFalse(self.mounted(), "RAGO-COMM doit être démontée après l'écriture")
        data = json.loads(self.read_from_image("/security/profile.json"))
        self.assertEqual(data["security"], "perf")
        self.assertEqual(data["profile_id"], "fortnite")
        self.assertEqual(data["profile"]["windows_security"], "perf")
        layout = json.loads(self.read_from_image("/rago-comm.json"))
        self.assertEqual(layout["layout"], 1)
        # Pas de fichier temporaire oublié.
        self.assertNotIn(".tmp", self.list_dir("/security"))
        # Fichier en ASCII pur (Windows PowerShell 5.1 le lit sans souci d'encodage).
        raw = self.read_from_image("/security/profile.json").encode("utf-8")
        raw.decode("ascii")

    def test_second_set_replaces_and_keeps_utf8_names_ascii(self):
        prof = dict(FORTNITE, windows_security="compat_max", name="Fôrtnite — été")
        self.assertEqual(run_hook(["set"], env_for(RAGO_COMM_CONF=self.conf), json.dumps(FORTNITE)).returncode, 0)
        r = run_hook(["set"], env_for("compat_max", RAGO_COMM_CONF=self.conf), json.dumps(prof))
        self.assertEqual(r.returncode, 0, r.stderr)
        raw = self.read_from_image("/security/profile.json")
        raw.encode("ascii")
        data = json.loads(raw)
        self.assertEqual(data["security"], "compat_max")
        self.assertEqual(data["profile"]["name"], "Fôrtnite — été")

    def test_already_mounted_stays_mounted(self):
        subprocess.run([self.fake, "--quiet", "start", "x"], check=True)
        os.remove(self.log)
        r = run_hook(["set"], env_for("compat_max", "valorant", RAGO_COMM_CONF=self.conf), "")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), [], "déjà montée : ni start ni stop")
        self.assertTrue(self.mounted())
        with open(os.path.join(self.mnt, "security", "profile.json")) as f:
            self.assertEqual(json.load(f)["profile_id"], "valorant")
        st = os.stat(os.path.join(self.mnt, "security", "profile.json"))
        self.assertEqual(st.st_mode & 0o777, 0o600)

    def test_wrong_fs_refused(self):
        tmpfs = os.path.join(self.d, "tmpfs")
        os.makedirs(tmpfs, exist_ok=True)
        subprocess.run(["mount", "-t", "tmpfs", "tmpfs", tmpfs], check=True)
        try:
            conf = os.path.join(self.d, "conf-tmpfs")
            with open(conf, "w") as f:
                f.write(f"RAGO_COMM_DIR={tmpfs}\nRAGO_COMM_MOUNT=none\n")
            r = run_hook(["set"], env_for(RAGO_COMM_CONF=conf), json.dumps(FORTNITE))
            self.assertEqual(r.returncode, 1)
            self.assertIn("FAT32", r.stderr)
            self.assertIn("tmpfs", r.stderr)
            with open(conf, "a") as f:
                f.write("RAGO_COMM_REQUIRE_VFAT=0\n")
            self.assertEqual(run_hook(["set"], env_for(RAGO_COMM_CONF=conf), json.dumps(FORTNITE)).returncode, 0)
        finally:
            subprocess.run(["umount", tmpfs])

    def test_start_without_mount_is_an_error_and_stops(self):
        with open(self.fake, "w") as f:
            f.write(f"#!/bin/sh\necho \"$*\" >> {self.log}\nexit 0\n")
        r = run_hook(["set"], env_for(RAGO_COMM_CONF=self.conf), json.dumps(FORTNITE))
        self.assertEqual(r.returncode, 1)
        self.assertIn("rien n'est monté", r.stderr)
        self.assertEqual([c[1] for c in self.calls()], ["start", "stop"])

    def test_systemctl_failure(self):
        with open(self.fake, "w") as f:
            f.write("#!/bin/sh\necho 'Job for run-rago-comm.mount failed.' >&2\nexit 1\n")
        r = run_hook(["set"], env_for(RAGO_COMM_CONF=self.conf), json.dumps(FORTNITE))
        self.assertEqual(r.returncode, 1)
        self.assertIn("Job for run-rago-comm.mount failed", r.stderr)

    def test_status_reads_windows_files_with_bom(self):
        self.assertEqual(run_hook(["set"], env_for(RAGO_COMM_CONF=self.conf), json.dumps(FORTNITE)).returncode, 0)
        # Ce qu'écrirait Windows PowerShell 5.1 (marque BOM UTF-8).
        subprocess.run([self.fake, "--quiet", "start", "x"], check=True)
        os.makedirs(os.path.join(self.mnt, "reports"), exist_ok=True)
        with open(os.path.join(self.mnt, "security", "status.json"), "w", encoding="utf-8-sig") as f:
            json.dump({"schema": 1, "applied": "perf", "effective": "perf"}, f)
        with open(os.path.join(self.mnt, "reports", "m5-engine.json"), "w", encoding="utf-8-sig") as f:
            json.dump({"schema": 1, "explorer_running": False}, f)
        subprocess.run([self.fake, "--quiet", "stop", "x"], check=True)
        os.remove(self.log)
        r = run_hook(["status"], {"RAGO_COMM_CONF": self.conf})
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(out["requested"]["security"], "perf")
        self.assertEqual(out["windows_status"]["effective"], "perf")
        self.assertFalse(out["reports"]["m5-engine.json"]["explorer_running"])
        self.assertEqual([c[1] for c in self.calls()], ["start", "stop"])
        self.assertFalse(self.mounted())

    @unittest.skipUnless(os.access(PROFILED, os.X_OK), "rago-profiled pas compilé (cargo build --release -p rago-profiled)")
    def test_end_to_end_with_rago_profiled(self):
        """Vrai démon M14 : prepare-switch → hook (environnement vidé) → RAGO-COMM."""
        base = tempfile.mkdtemp(prefix="rago-m5-e2e-")
        try:
            hooks = os.path.join(base, "hooks")
            os.makedirs(hooks)
            os.chmod(hooks, 0o755)
            # rago-profiled vide l'environnement : le réglage de test passe par un
            # petit lanceur (en vrai, le hook lit /etc/rago/rago-comm.conf).
            wrapper = os.path.join(hooks, "windows-security")
            with open(wrapper, "w") as f:
                f.write(f"#!/bin/sh\nRAGO_COMM_CONF={self.conf} exec {sys.executable} -I {HOOK} \"$@\"\n")
            os.chmod(wrapper, 0o755)
            sock = os.path.join(base, "profiled.sock")
            env = dict(os.environ, RAGO_PROFILED_SOCKET=sock)
            profiles = ["--profiles-dir", os.path.join(REPO, "profiles", "community")]
            d = subprocess.Popen([PROFILED, *profiles, "daemon", "--state-dir", os.path.join(base, "state"),
                                  "--hooks-dir", hooks, "--group", "", "--root", base,
                                  "--pmqos-dev", os.path.join(base, "pmqos")],
                                 env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                for _ in range(100):
                    if os.path.exists(sock):
                        break
                    time.sleep(0.05)
                self.assertTrue(os.path.exists(sock), "socket du démon absent")
                for game, want in (("fortnite", "perf"), ("valorant", "compat_max"), ("jeu-inconnu", "compat_max")):
                    with self.subTest(game=game):
                        r = subprocess.run([PROFILED, *profiles, "prepare-switch", "--id", game], env=env,
                                           capture_output=True, text=True, timeout=60)
                        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                        self.assertIn(f"{want} transmis au micro-Windows", r.stdout + r.stderr)
                        data = json.loads(self.read_from_image("/security/profile.json"))
                        self.assertEqual(data["security"], want)
                        pid = game if game != "jeu-inconnu" else "_fallback"
                        self.assertEqual(data["profile_id"], pid)
                        self.assertEqual(data["profile"]["windows_security"], want)
                        self.assertFalse(self.mounted())
                # Jeu de couche proton : refusé par le démon, le hook n'est pas appelé.
                os.remove(self.log)
                r = subprocess.run([PROFILED, *profiles, "prepare-switch", "--id", "elden-ring"], env=env,
                                   capture_output=True, text=True, timeout=60)
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(self.calls(), [])
            finally:
                d.terminate()
                d.communicate(timeout=10)  # ferme aussi la sortie du démon
        finally:
            shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    print(f"système de fichiers de test : {FS}" + ("" if FS == "vfat" else " (noyau sans vfat : FAT32 testée en VM)"),
          file=sys.stderr)
    unittest.main()
