#!/usr/bin/python3 -I
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — bibliothèque partagée (module M7), côté Linux : tout ce qui passe
# par la partition d'échange RAGO-COMM (FAT32, contrat posé par M5), et la
# lecture des métadonnées de RAGO-LIB.
#
# Appelé par host/bin/rago-library.sh (installé dans /usr/lib/rago/), jamais
# directement par le joueur :
#
#   rago_library.py decide                 RAGO-LIB peut-elle être montée en écriture ?
#   rago_library.py prepare-mount PÉRIPH auto|rw|ro [PARTUUID NUMÉRO] [--no-ntfs]
#                                          avant un montage : décision + contrôle NTFS + partition.json
#   rago_library.py ntfs-check PÉRIPH       état NTFS lu sur le disque (bit « sale », $LogFile)
#   rago_library.py request ACTION LANCEUR ID [--name NOM]
#   rago_library.py cancel ID_REQUÊTE
#   rago_library.py forget ID_REQUÊTE       efface le résultat d'une requête finie
#   rago_library.py confirm-off             le joueur certifie que Windows est éteint
#   rago_library.py record-partition PARTUUID UUID
#   rago_library.py status [--text]        état de Windows, requêtes, résultats (JSON ou texte)
#   rago_library.py list LIB_DIR|- [--text] jeux de RAGO-LIB + requêtes (JSON ou texte)
#   rago_library.py init LIB_DIR           crée .rago/ dans RAGO-LIB (montée en écriture)
#
# RAGO-COMM est montée seulement le temps de l'opération (unité systemd
# run-rago-comm.mount de M5), comme le hook windows-security. Réglages :
# /etc/rago/rago-comm.conf (M5), même format.
#
# Fichiers dans RAGO-COMM (dossier library/) :
#   windows-state.json   Windows → Linux : « running » au démarrage du
#                        micro-Windows (avant de mettre RAGO-LIB en ligne),
#                        « off » à l'arrêt propre (RAGO-LIB vidée et hors ligne)
#   linux-confirm.json   Linux → Linux : le joueur a certifié que Windows est
#                        éteint (vaut seulement pour l'état Windows qu'il a vu)
#   partition.json       Linux → Windows : identifiants de la partition RAGO-LIB
#                        (Windows la retrouve même hors ligne, sans étiquette lisible)
#   requests/<id>.json   Linux → Windows : installer / lancer un jeu
#   results/<id>.json    Windows → Linux : où en est chaque requête
# Dans RAGO-LIB : .rago/library.json (repère), .rago/games/<clé>.json (un par
# jeu, écrit par l'agent Windows), Games/<Lanceur>/ (jeux).
#
# Codes de sortie : 0 fait, 1 erreur, 2 entrée refusée. « decide »,
# « prepare-mount », « ntfs-check » : 0 écriture permise, 3 lecture seule
# (doute), 1 erreur.
#
# Écriture sur RAGO-LIB permise seulement si DEUX contrôles indépendants sont
# bons : (1) RAGO-COMM dit que Windows s'est arrêté proprement et a mis
# RAGO-LIB hors ligne (ou le joueur l'a certifié), (2) le disque lui-même dit
# que le volume est propre : bit « sale » éteint et journal $LogFile vide ou
# propre, pas en version 2.0 (Windows garde alors des métadonnées en cache :
# veille prolongée ou démarrage rapide ; même règle que ntfs-3g). Le pilote
# ntfs3 ne fait pas ce second contrôle lui-même (pas de détection de la veille
# prolongée de Windows) et rejouerait le journal de Windows. Jamais l'option
# « force ».
#
# Aucune dissimulation : les jeux s'installent par les clients officiels, dans
# Windows ; Linux ne fait que gérer, lister et déclencher.

import errno
import hashlib
import json
import os
import re
import stat
import struct
import subprocess
import sys
import time

CONF_DEFAULT = "/etc/rago/rago-comm.conf"
DEFAULTS = {
    "RAGO_COMM_DIR": "/run/rago/comm",
    "RAGO_COMM_MOUNT": "systemd",
    "RAGO_COMM_UNIT": "run-rago-comm.mount",
    "RAGO_COMM_DEVICE": "/dev/disk/by-label/RAGO-COMM",
    "RAGO_COMM_REQUIRE_VFAT": "1",
    "RAGO_COMM_SYSTEMCTL": "/usr/bin/systemctl",
}
SYSTEMCTL_TIMEOUT = 10
WRITER = "rago-library (M7)"
LAYOUT = {"schema": 1, "layout": 1, "name": "RAGO-COMM",
          "doc": "Partition d'echange Linux <-> micro-Windows de Rago OS (M5/M6). "
                 "Ne pas ouvrir depuis Linux pendant que Windows tourne."}

LAUNCHERS = ("steam", "epic", "riot")
ACTIONS = ("install", "launch")
# Identifiants acceptés par lanceur (ce que le client officiel attend).
#   steam : numéro d'application (appid)
#   epic  : AppName, ou espace:article:AppName (comme les URI du lanceur Epic)
#   riot  : produit du client Riot (valorant, league_of_legends…)
ID_RULES = {
    "steam": re.compile(r"^[0-9]{1,10}$"),
    "epic": re.compile(r"^[A-Za-z0-9._-]{1,64}(:[A-Za-z0-9._-]{1,64}:[A-Za-z0-9._-]{1,64})?$"),
    "riot": re.compile(r"^[a-z][a-z0-9_]{0,31}$"),
}
RIOT_KNOWN = ("valorant", "league_of_legends")
REQ_ID_RE = re.compile(r"^(install|launch)-(steam|epic|riot)-[a-z0-9-]{1,80}$")
KEY_RE = re.compile(r"^(steam|epic|riot)-[a-z0-9-]{1,80}$")
STATES = ("running", "off")
RESULT_STATES = ("pending", "waiting_user", "running", "done", "failed", "cancelled")
FINISHED = ("done", "failed", "cancelled")
MAX_NAME = 120
MAX_JSON = 256 * 1024


class Refused(Exception):
    """Entrée refusée (code 2)."""


class Failed(Exception):
    """Erreur d'exécution (code 1)."""


def log(msg):
    print(msg, file=sys.stderr)


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# --- réglages (même fichier et mêmes règles que le hook windows-security de M5) -------------

def load_conf(path):
    conf = dict(DEFAULTS)
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return conf
    # Lancé en root : un fichier de réglages modifiable par d'autres pourrait
    # le faire écrire n'importe où.
    if st.st_uid not in (0, os.geteuid()) or st.st_mode & 0o022:
        raise Failed(f"{path} doit appartenir à root et ne pas être modifiable par le groupe ou les autres")
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise Failed(f"{path}:{n} : ligne sans « = »")
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            if k not in DEFAULTS:
                raise Failed(f"{path}:{n} : réglage inconnu {k}")
            conf[k] = v
    if conf["RAGO_COMM_MOUNT"] not in ("systemd", "none"):
        raise Failed("RAGO_COMM_MOUNT doit valoir systemd ou none")
    if not os.path.isabs(conf["RAGO_COMM_DIR"]):
        raise Failed("RAGO_COMM_DIR doit être un chemin absolu")
    return conf


# --- RAGO-COMM, montée le temps d'un bloc `with` -------------------------------------------

def _unescape(s):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), s)


def mount_info(path):
    """(type, source, options) du montage le plus haut exactement sur `path`, sinon None."""
    path = os.path.realpath(path)
    found = None
    try:
        with open("/proc/self/mountinfo", encoding="utf-8") as f:
            for line in f:
                left, _, right = line.partition(" - ")
                fields = left.split()
                if len(fields) < 6 or _unescape(fields[4]) != path:
                    continue
                r = right.split()
                found = (r[0] if r else "?", _unescape(r[1]) if len(r) > 1 else "?", fields[5])
    except OSError:
        return None
    return found


def systemctl(conf, verb):
    cmd = [conf["RAGO_COMM_SYSTEMCTL"], "--quiet", verb, conf["RAGO_COMM_UNIT"]]
    try:
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                           timeout=SYSTEMCTL_TIMEOUT)
    except FileNotFoundError:
        raise Failed(f"{cmd[0]} introuvable")
    except subprocess.TimeoutExpired:
        raise Failed(f"systemctl {verb} {conf['RAGO_COMM_UNIT']} : délai de {SYSTEMCTL_TIMEOUT} s dépassé")
    if r.returncode != 0:
        why = (r.stderr or r.stdout).strip().splitlines()
        raise Failed(f"systemctl {verb} {conf['RAGO_COMM_UNIT']} : code {r.returncode}"
                     + (f" ({why[-1]})" if why else ""))


class Comm:
    def __init__(self, conf):
        self.conf = conf
        self.dir = conf["RAGO_COMM_DIR"]
        self.started = False

    def __enter__(self):
        conf = self.conf
        info = mount_info(self.dir)
        if info is None:
            if conf["RAGO_COMM_MOUNT"] != "systemd":
                raise Failed(f"RAGO-COMM n'est pas montée sur {self.dir} (RAGO_COMM_MOUNT=none)")
            dev = conf["RAGO_COMM_DEVICE"]
            if not os.path.exists(dev):
                raise Failed(f"partition RAGO-COMM introuvable ({dev}) : voir la note M5 du vault")
            systemctl(conf, "start")
            self.started = True
            info = mount_info(self.dir)
            if info is None:
                self._stop_quietly()
                raise Failed(f"{conf['RAGO_COMM_UNIT']} démarrée mais rien n'est monté sur {self.dir}")
        if conf["RAGO_COMM_REQUIRE_VFAT"] != "0" and info[0] != "vfat":
            self._stop_quietly()
            raise Failed(f"{self.dir} est en {info[0]} ({info[1]}) : RAGO-COMM doit être en FAT32 (vfat)")
        return self

    def _stop_quietly(self):
        if self.started:
            try:
                systemctl(self.conf, "stop")
            except Failed as e:
                log(f"avertissement : {e}")
            self.started = False

    def __exit__(self, exc_type, exc, tb):
        if not self.started:
            return False
        if exc_type is not None:
            self._stop_quietly()
            return False
        os.sync()
        self.started = False
        systemctl(self.conf, "stop")
        return False

    def path(self, *parts):
        return os.path.join(self.dir, *parts)


def fsync_dir(d):
    try:
        fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def write_json(path, obj, mode=0o600):
    """Écriture sûre : fichier temporaire, fsync, renommage, fsync du dossier. ASCII."""
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700 if mode == 0o600 else 0o755, exist_ok=True)
    data = (json.dumps(obj, indent=2, ensure_ascii=True) + "\n").encode("ascii")
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)
    fsync_dir(d)


def read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read(MAX_JSON + 1)
    except FileNotFoundError:
        return None


def parse_json(data, name):
    """Objet JSON, ou {"_erreur": …} si illisible. BOM accepté (Windows PowerShell)."""
    if data is None:
        return None
    if len(data) > MAX_JSON:
        return {"_erreur": f"{name} trop gros"}
    try:
        obj = json.loads(data.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError) as e:
        return {"_erreur": f"{name} illisible : {e}"}
    if not isinstance(obj, dict):
        return {"_erreur": f"{name} : objet JSON attendu"}
    return obj


def read_json(path):
    return parse_json(read_bytes(path), os.path.basename(path))


def ensure_layout(comm):
    if not os.path.exists(comm.path("rago-comm.json")):
        write_json(comm.path("rago-comm.json"), LAYOUT)


# --- décision : écriture permise sur RAGO-LIB ? ------------------------------------------------

def state_digest(data):
    return "absent" if data is None else hashlib.sha256(data).hexdigest()


def decide_from(state_bytes, confirm):
    """Règle de sûreté (pure, testée) : (écriture permise, raison).

    Écriture seulement si le micro-Windows a écrit lui-même « off » à son arrêt
    propre (RAGO-LIB vidée et mise hors ligne par l'agent), ou si le joueur a
    certifié l'arrêt de Windows pour CET état-là (confirm-off). Tout le reste
    — état absent, illisible, « running », « off » sans RAGO-LIB hors ligne —
    est un doute : lecture seule.
    """
    st = parse_json(state_bytes, "windows-state.json")
    digest = state_digest(state_bytes)
    if (isinstance(confirm, dict) and confirm.get("kind") == "rago-library-confirm-off"
            and confirm.get("windows_state_sha256") == digest):
        return True, "arrêt de Windows certifié par le joueur (rago-library confirm-windows-off)"
    if st is None:
        return False, "Windows n'a jamais écrit son état (agent M7 absent ou jamais démarré) : lecture seule"
    if "_erreur" in st:
        return False, f"état de Windows illisible ({st['_erreur']}) : lecture seule"
    if st.get("kind") != "rago-library-windows-state" or st.get("schema") != 1:
        return False, "état de Windows d'un format inconnu : lecture seule"
    state = st.get("state")
    if state == "running":
        return False, ("Windows n'a pas fini proprement sa dernière session (en marche, en veille "
                       "prolongée, ou arrêté brutalement) : lecture seule")
    if state == "off":
        lib = st.get("lib") if isinstance(st.get("lib"), dict) else {}
        # « pas trouvée » ne vaut que sans erreur et sans mise en ligne : une
        # erreur à l'arrêt (recherche ou mise hors ligne ratée) est un doute.
        if lib.get("found") is False and not lib.get("error") and lib.get("online") is not True:
            return True, "Windows éteint proprement ; il n'avait pas trouvé RAGO-LIB"
        if lib.get("offline") is True:
            return True, "Windows éteint proprement, RAGO-LIB vidée et hors ligne côté Windows"
        return False, "Windows éteint, mais RAGO-LIB n'a pas été mise hors ligne proprement : lecture seule"
    return False, f"état de Windows inconnu ({state!r}) : lecture seule"


def cmd_decide(conf):
    with Comm(conf) as comm:
        data = read_bytes(comm.path("library", "windows-state.json"))
        confirm = read_json(comm.path("library", "linux-confirm.json"))
    ok, why = decide_from(data, confirm)
    st = parse_json(data, "windows-state.json")
    print(json.dumps({"rw_allowed": ok, "reason": why,
                      "windows_state": st.get("state") if isinstance(st, dict) else None,
                      "windows_updated_at": st.get("updated_at") if isinstance(st, dict) else None},
                     ensure_ascii=False))
    return 0 if ok else 3


def cmd_confirm_off(conf):
    with Comm(conf) as comm:
        ensure_layout(comm)
        data = read_bytes(comm.path("library", "windows-state.json"))
        st = parse_json(data, "windows-state.json")
        write_json(comm.path("library", "linux-confirm.json"), {
            "schema": 1,
            "kind": "rago-library-confirm-off",
            "confirmed_at": utc_now(),
            "writer": WRITER,
            "windows_state_sha256": state_digest(data),
            "windows_state_seen": st.get("state") if isinstance(st, dict) else None,
            "note": "Le joueur certifie que Windows est eteint (ni en marche, ni en veille prolongee). "
                    "Ne vaut que pour cet etat de Windows : au prochain demarrage de Windows, il est remplace.",
        })
    print("arrêt de Windows certifié : RAGO-LIB pourra être montée en écriture (jusqu'au prochain démarrage de Windows)")
    return 0


# --- état NTFS lu sur le disque, sans monter ---------------------------------------------------
#
# Lecture seule du périphérique (root). On lit : le secteur de démarrage,
# les enregistrements MFT 2 ($LogFile) et 3 ($Volume) — toujours dans la
# première plage de la MFT —, puis les pages de redémarrage du journal.
# Formats : structures NTFS publiques (layout.h de ntfs-3g, fs/ntfs3/ntfs.h).

AT_VOLUME_NAME = 0x60
AT_VOLUME_INFORMATION = 0x70
AT_DATA = 0x80
AT_END = 0xFFFFFFFF
VOLUME_IS_DIRTY = 0x0001
RESTART_VOLUME_IS_CLEAN = 0x0002
LOGFILE_NO_CLIENT = 0xFFFF
MST_STRIDE = 512          # les « fixups » NTFS protègent chaque bloc de 512 octets
LOG_SCAN = 2 * 65536      # deux pages de redémarrage (64 Kio au plus chacune)
LOG_STATES_OK = ("empty", "clean")


class NtfsError(Exception):
    """Volume illisible ou incohérent : doute."""


def mst_fixup(buf, what):
    """Applique les fixups (« multi-sector transfer ») d'un enregistrement NTFS."""
    b = bytearray(buf)
    usa_ofs, usa_count = struct.unpack_from("<HH", b, 4)
    if (usa_count < 2 or usa_ofs < 8 or usa_ofs + 2 * usa_count > len(b)
            or (usa_count - 1) * MST_STRIDE > len(b)):
        raise NtfsError(f"{what} : tableau de fixups invalide")
    usn = bytes(b[usa_ofs:usa_ofs + 2])
    for i in range(1, usa_count):
        end = i * MST_STRIDE
        if bytes(b[end - 2:end]) != usn:
            raise NtfsError(f"{what} : bloc {i} incohérent (écriture interrompue ?)")
        b[end - 2:end] = b[usa_ofs + 2 * i:usa_ofs + 2 * i + 2]
    return bytes(b)


def resident_value(a, what):
    if len(a) < 0x18 or a[8] != 0:
        raise NtfsError(f"{what} : attribut résident attendu")
    vlen, voff = struct.unpack_from("<IH", a, 0x10)
    if voff + vlen > len(a):
        raise NtfsError(f"{what} : valeur hors de l'attribut")
    return a[voff:voff + vlen]


def runlist(a, what):
    """Plages (vcn, longueur, lcn|None) d'un attribut non résident, et sa taille."""
    if a[8] != 1 or len(a) < 0x40:
        raise NtfsError(f"{what} : attribut non résident attendu")
    lowest_vcn, = struct.unpack_from("<q", a, 0x10)
    mp_off, = struct.unpack_from("<H", a, 0x20)
    data_size, = struct.unpack_from("<q", a, 0x30)
    if lowest_vcn != 0:
        raise NtfsError(f"{what} : première plage absente de l'enregistrement de base")
    runs, vcn, lcn, p = [], 0, 0, mp_off
    while p < len(a) and a[p] != 0:
        h = a[p]
        ln, lo = h & 0x0F, h >> 4
        p += 1
        if ln == 0 or ln > 8 or lo > 8 or p + ln + lo > len(a):
            raise NtfsError(f"{what} : liste de plages invalide")
        length = int.from_bytes(a[p:p + ln], "little")
        p += ln
        if lo:
            lcn += int.from_bytes(a[p:p + lo], "little", signed=True)
            p += lo
            if lcn < 0:
                raise NtfsError(f"{what} : plage avant le début du volume")
            runs.append((vcn, length, lcn))
        else:
            runs.append((vcn, length, None))
        vcn += length
    if not runs:
        raise NtfsError(f"{what} : aucune plage")
    return runs, data_size


class Ntfs:
    def __init__(self, fd):
        self.fd = fd
        self.dev_size = os.lseek(fd, 0, os.SEEK_END)
        bs = self.pread(0, 512)
        if bs[3:11] != b"NTFS    " or bs[510:512] != b"\x55\xaa":
            raise NtfsError("pas de secteur de démarrage NTFS")
        bps, = struct.unpack_from("<H", bs, 0x0B)
        spc = bs[0x0D]
        if spc > 0x80:
            spc = 1 << (256 - spc)
        if bps not in (512, 1024, 2048, 4096) or spc == 0 or spc & (spc - 1):
            raise NtfsError("géométrie NTFS invalide")
        self.bps = bps
        self.cluster = bps * spc
        self.total_sectors, self.mft_lcn = struct.unpack_from("<QQ", bs, 0x28)
        cpr, = struct.unpack_from("<b", bs, 0x40)
        self.rec_size = (1 << -cpr) if cpr < 0 else cpr * self.cluster
        if self.rec_size not in (1024, 2048, 4096):
            raise NtfsError(f"taille d'enregistrement MFT {self.rec_size} inattendue")
        self.serial = "%016X" % struct.unpack_from("<Q", bs, 0x48)[0]

    def pread(self, off, n):
        if off < 0 or off + n > self.dev_size:
            raise NtfsError(f"lecture hors du volume (octet {off})")
        data = os.pread(self.fd, n, off)
        if len(data) != n:
            raise NtfsError(f"lecture courte à l'octet {off}")
        return data

    def record(self, n):
        raw = self.pread(self.mft_lcn * self.cluster + n * self.rec_size, self.rec_size)
        if raw[:4] != b"FILE":
            raise NtfsError(f"enregistrement MFT {n} illisible")
        rec = mst_fixup(raw, f"enregistrement MFT {n}")
        flags, = struct.unpack_from("<H", rec, 0x16)
        if not flags & 1:
            raise NtfsError(f"enregistrement MFT {n} libre")
        return rec

    def attrs(self, rec, n):
        off, = struct.unpack_from("<H", rec, 0x14)
        used, = struct.unpack_from("<I", rec, 0x18)
        limit = min(used, len(rec))
        while off + 8 <= limit:
            typ, length = struct.unpack_from("<II", rec, off)
            if typ == AT_END:
                return
            if length < 16 or off + length > limit:
                raise NtfsError(f"enregistrement MFT {n} : attribut invalide")
            yield typ, rec[off:off + length]
            off += length

    def read_runs(self, runs, n):
        out = bytearray()
        for _vcn, length, lcn in runs:
            if len(out) >= n:
                break
            chunk = min(length * self.cluster, n - len(out))
            out += b"\0" * chunk if lcn is None else self.pread(lcn * self.cluster, chunk)
        if len(out) < n:
            # Plages incomplètes (suite dans un autre enregistrement) : on ne
            # conclut pas sur un début de journal tronqué.
            raise NtfsError("plages incomplètes dans l'enregistrement de base")
        return bytes(out)

    def volume(self):
        label, version, flags = None, None, None
        for typ, a in self.attrs(self.record(3), 3):
            if typ == AT_VOLUME_NAME:
                label = resident_value(a, "$Volume").decode("utf-16-le", "replace")
            elif typ == AT_VOLUME_INFORMATION:
                v = resident_value(a, "$Volume")
                if len(v) < 12:
                    raise NtfsError("$Volume : informations trop courtes")
                version = f"{v[8]}.{v[9]}"
                flags, = struct.unpack_from("<H", v, 10)
        if flags is None:
            raise NtfsError("$Volume sans informations de volume")
        return label, version, flags

    def logfile_head(self):
        data = None
        for typ, a in self.attrs(self.record(2), 2):
            if typ == AT_DATA and a[9] == 0:
                data = a
                break
        if data is None:
            raise NtfsError("$LogFile sans données")
        runs, size = runlist(data, "$LogFile")
        if size < 2 * 4096:
            raise NtfsError("$LogFile trop petit")
        return self.read_runs(runs, min(size, LOG_SCAN))


RESTART_HDR_SIZE = 0x1E    # taille de l'en-tête d'une page de redémarrage
LOG_VERSIONS = ((1, 1), (2, 0))


def restart_page(head, pos):
    """Page de redémarrage du journal à `pos`, ou None si ce n'en est pas une.

    Mêmes contrôles d'en-tête que ntfs-3g (ntfs_check_restart_page_header) ;
    mais là où ntfs-3g ignore une page douteuse pour lire l'autre copie, on
    lève NtfsError : au doute, lecture seule.
    """
    magic = head[pos:pos + 4]
    if magic not in (b"RSTR", b"CHKD") or pos + RESTART_HDR_SIZE > len(head):
        return None
    usa_ofs, usa_count, chkdsk_lsn, page_size, log_page_size, ra_ofs, minor, major = \
        struct.unpack_from("<HHqIIHhh", head, pos + 4)
    for size in (page_size, log_page_size):
        if size < MST_STRIDE or size & (size - 1):
            raise NtfsError("$LogFile : taille de page de redémarrage invalide")
    if pos not in (0, page_size):
        raise NtfsError("$LogFile : page de redémarrage à une position incohérente")
    if pos + page_size > len(head):
        raise NtfsError("$LogFile : page de redémarrage hors du début du journal")
    base = {"pos": pos, "magic": magic.decode(), "page_size": page_size, "version": (major, minor)}
    if magic == b"CHKD":
        # chkdsk est passé : on refuse l'écriture quel que soit le reste
        # (ntfs-3g l'accepte si le journal est propre ; Rago est plus prudent).
        return base
    if chkdsk_lsn != 0:
        raise NtfsError("$LogFile : page RSTR avec une marque de chkdsk")
    if (major, minor) not in LOG_VERSIONS:
        return dict(base, unknown=True)
    usa_end = usa_ofs + 2 * usa_count
    if (usa_count != page_size // MST_STRIDE + 1 or usa_ofs < RESTART_HDR_SIZE
            or usa_end > MST_STRIDE - 2):
        raise NtfsError("$LogFile : tableau de fixups de la page de redémarrage incohérent")
    if ra_ofs & 7 or ra_ofs < usa_end or ra_ofs + 16 > page_size:
        raise NtfsError("$LogFile : zone de redémarrage hors de la page")
    page = mst_fixup(head[pos:pos + page_size], "$LogFile (page de redémarrage)")
    current_lsn, _clients, _free, in_use, flags = struct.unpack_from("<QHHHH", page, ra_ofs)
    return dict(base, current_lsn=current_lsn, client_in_use_list=in_use, flags=flags)


def logfile_state(head):
    """('empty'|'clean'|'unclean'|'windows-cache'|'chkdsk'|'unknown-version', version)

    Mêmes règles que ntfs-3g (libntfs-3g/logfile.c) : journal tout à 0xFF =
    vide ; page la plus récente (plus grand LSN) en version 2.0 = Windows a
    gardé des métadonnées en cache (veille prolongée, démarrage rapide, ou
    coupure brutale) ; client actif sans le drapeau « volume propre » = arrêt
    pas propre. Plus prudent que ntfs-3g : une page marquée par chkdsk ou
    d'une version inconnue, où qu'elle soit, suffit à refuser l'écriture.
    """
    pages = []
    first = restart_page(head, 0)
    if first is not None:
        pages.append(first)
        second = restart_page(head, first["page_size"]) if first["page_size"] < len(head) else None
        if second is not None:
            if second["page_size"] != first["page_size"]:
                raise NtfsError("$LogFile : les deux pages de redémarrage ne s'accordent pas")
            pages.append(second)
    else:
        if head.count(b"\xff") == len(head):
            return "empty", None
        # Première copie abîmée : chercher la seconde aux tailles de page possibles.
        pos = MST_STRIDE
        while pos < len(head) and not pages:
            p = restart_page(head, pos)
            if p is not None:
                pages.append(p)
            pos <<= 1
        if not pages:
            raise NtfsError("$LogFile : aucune page de redémarrage")
    for p in pages:
        if p["magic"] == "CHKD":
            return "chkdsk", "%d.%d" % p["version"]
    for p in pages:
        if p.get("unknown"):
            return "unknown-version", "%d.%d" % p["version"]
    latest = max(pages, key=lambda p: p["current_lsn"])
    major, minor = latest["version"]
    version = f"{major}.{minor}"
    if (major, minor) == (2, 0):
        return "windows-cache", version
    if latest["client_in_use_list"] != LOGFILE_NO_CLIENT and not latest["flags"] & RESTART_VOLUME_IS_CLEAN:
        return "unclean", version
    return "clean", version


LOG_REASONS = {
    "windows-cache": "le journal NTFS est en version 2.0 : Windows a gardé des métadonnées en cache "
                     "(veille prolongée, démarrage rapide, ou coupure brutale)",
    "unclean": "le journal NTFS a des transactions en cours : Windows ne s'est pas arrêté proprement",
    "chkdsk": "chkdsk a marqué le journal NTFS : Windows doit vérifier le volume (démarrer le micro-Windows)",
    "unknown-version": "journal NTFS d'une version inconnue",
}


def ntfs_inspect(dev):
    """État NTFS de `dev` (lecture seule) : dict avec rw_ok et les raisons du refus."""
    out = {"device": dev, "ntfs": False, "rw_ok": False, "reasons": []}
    try:
        fd = os.open(dev, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    except OSError as e:
        out["reasons"].append(f"lecture de {dev} impossible : {e.strerror}")
        return out
    try:
        v = Ntfs(fd)
        out["ntfs"] = True
        out["serial"] = v.serial
        out["size_ok"] = v.total_sectors * v.bps <= v.dev_size
        label, version, flags = v.volume()
        out.update({"label": label, "ntfs_version": version, "dirty": bool(flags & VOLUME_IS_DIRTY)})
        state, lver = logfile_state(v.logfile_head())
        out.update({"logfile": state, "logfile_version": lver})
    except NtfsError as e:
        out["reasons"].append(f"volume NTFS illisible ou incohérent : {e}")
        return out
    except (struct.error, IndexError, ValueError) as e:
        # Structure plus courte qu'annoncé : doute, comme NtfsError (la
        # lecture seule reste possible, ntfs3 fera ses propres contrôles).
        out["reasons"].append(f"volume NTFS illisible ou incohérent : structure tronquée ({e})")
        return out
    except OSError as e:
        out["reasons"].append(f"lecture de {dev} impossible : {e.strerror}")
        return out
    finally:
        os.close(fd)
    if not out["size_ok"]:
        out["reasons"].append("le volume NTFS est plus grand que la partition (ntfs3 le monterait en lecture seule)")
    if out["dirty"]:
        out["reasons"].append("le volume NTFS est marqué « sale » : à réparer par Windows (au prochain démarrage "
                              "du micro-Windows, l'agent M7 la répare avant de s'en servir)")
    if state not in LOG_STATES_OK:
        out["reasons"].append(LOG_REASONS[state])
    out["rw_ok"] = not out["reasons"]
    return out


def cmd_ntfs_check(dev):
    st = ntfs_inspect(dev)
    print(json.dumps(st, ensure_ascii=False))
    if not st["ntfs"]:
        return 1
    return 0 if st["rw_ok"] else 3


def cmd_claimed(devs):
    """Périphériques encore tenus par le noyau : 0 au moins un, 1 aucun, 4 doute.

    Le tableau des montages (findmnt) ne voit que l'espace de noms courant :
    un montage resté vivant dans un espace de noms privé (mise à jour M4 en
    cours, service isolé) ou démonté en différé (umount -l, fichier encore
    ouvert) y est invisible, alors que le volume reste ouvert et en cache.
    Un système de fichiers monté réserve son périphérique en exclusif :
    open(O_EXCL) sur un périphérique bloc échoue alors avec EBUSY, quel que
    soit l'espace de noms.
    """
    held, doubt = [], []
    for dev in devs:
        try:
            if not stat.S_ISBLK(os.stat(dev).st_mode):
                doubt.append(f"{dev} : pas un périphérique bloc")
                continue
            fd = os.open(dev, os.O_RDONLY | os.O_EXCL | getattr(os, "O_CLOEXEC", 0))
        except OSError as e:
            if e.errno == errno.EBUSY:
                held.append(dev)
            else:
                doubt.append(f"{dev} : {e.strerror}")
            continue
        os.close(fd)
    for d in held:
        print(d)
    for d in doubt:
        log(f"contrôle impossible : {d}")
    if held:
        return 0
    return 4 if doubt else 1


def valid_partuuid(v):
    return bool(re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", v or ""))


def valid_serial(v):
    return bool(re.fullmatch(r"[0-9A-Fa-f]{16}", v or ""))


def record_partition(comm, partuuid, serial):
    """Note la partition pour Windows (library/partition.json) ; True si écrit."""
    cur = read_json(comm.path("library", "partition.json"))
    if (isinstance(cur, dict) and cur.get("partuuid") == partuuid.lower()
            and cur.get("ntfs_serial") == serial.upper()):
        return False
    write_json(comm.path("library", "partition.json"), {
        "schema": 1,
        "kind": "rago-library-partition",
        "label": "RAGO-LIB",
        # Windows : Get-Partition | Where-Object Guid -eq '{<partuuid>}' (marche hors ligne)
        "partuuid": partuuid.lower(),
        "ntfs_serial": serial.upper(),
        "written_at": utc_now(),
        "writer": WRITER,
    })
    return True


def cmd_prepare_mount(conf, dev, want, partuuid, serial, check_ntfs):
    """Avant un montage : une seule ouverture de RAGO-COMM pour la décision et partition.json.

    Écriture permise seulement si RAGO-COMM ET le disque disent oui (voir
    l'en-tête). Sortie JSON ; code 0 écriture permise, 3 lecture seule.
    """
    if want not in ("auto", "rw", "ro"):
        raise Refused(f"mode {want!r} : auto, rw ou ro")
    out = {"want": want, "rw_allowed": False, "reasons": [], "partition_recorded": False}
    if partuuid is not None and not valid_partuuid(partuuid):
        out["reasons"].append(f"PARTUUID {partuuid!r} illisible : partition GPT attendue (Windows la retrouve par lui)")
        partuuid = None
    if serial is not None and not valid_serial(serial):
        serial = None
    try:
        with Comm(conf) as comm:
            if partuuid and serial:
                ensure_layout(comm)
                out["partition_recorded"] = record_partition(comm, partuuid, serial)
            data = read_bytes(comm.path("library", "windows-state.json"))
            confirm = read_json(comm.path("library", "linux-confirm.json"))
        ok, why = decide_from(data, confirm)
        st = parse_json(data, "windows-state.json")
        out["windows_state"] = st.get("state") if isinstance(st, dict) else None
        out["comm"] = why
    except Failed as e:
        ok = False
        out["comm"] = f"RAGO-COMM inaccessible ({e}) : état de Windows inconnu"
    if not ok:
        out["reasons"].append(out["comm"])
    if want != "ro":
        if check_ntfs:
            nt = ntfs_inspect(dev)
            out["ntfs"] = nt
            out["reasons"].extend(nt["reasons"])
            ok = ok and nt["rw_ok"]
        else:
            out["ntfs"] = None
            log("avertissement : contrôle NTFS sauté (RAGO_LIB_REQUIRE_NTFS=0, réservé aux tests)")
    out["rw_allowed"] = ok and want != "ro"
    print(json.dumps(out, ensure_ascii=False))
    return 0 if out["rw_allowed"] else 3


# --- requêtes ------------------------------------------------------------------------------

def slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    return s[:80] or "x"


def game_key(launcher, launcher_id):
    # Epic : la clé suit l'AppName (dernier champ), comme le manifeste du lanceur.
    if launcher == "epic":
        launcher_id = launcher_id.split(":")[-1]
    return f"{launcher}-{slug(launcher_id)}"


def build_request(action, launcher, launcher_id, name=None):
    if action not in ACTIONS:
        raise Refused(f"action {action!r} : attendu {' ou '.join(ACTIONS)}")
    if launcher not in LAUNCHERS:
        raise Refused(f"lanceur {launcher!r} : attendu {', '.join(LAUNCHERS)} (pas de Microsoft Store / Game Pass)")
    if not ID_RULES[launcher].fullmatch(launcher_id or ""):
        raise Refused(f"identifiant {launcher_id!r} invalide pour {launcher}")
    if name is not None:
        if len(name) > MAX_NAME or any(ord(c) < 32 for c in name):
            raise Refused("nom trop long ou avec des caractères de contrôle")
    key = game_key(launcher, launcher_id)
    req = {
        "schema": 1,
        "kind": "rago-library-request",
        "id": f"{action}-{key}",
        "action": action,
        "launcher": launcher,
        "launcher_id": launcher_id,
        "game_key": key,
        "written_at": utc_now(),
        "writer": WRITER,
    }
    if name:
        req["name"] = name
    return req


def cmd_request(conf, action, launcher, launcher_id, name, partuuid=None, serial=None):
    req = build_request(action, launcher, launcher_id, name)
    if launcher == "riot" and launcher_id not in RIOT_KNOWN:
        log(f"avertissement : produit Riot {launcher_id!r} inconnu de Rago (connus : {', '.join(RIOT_KNOWN)})")
    with Comm(conf) as comm:
        ensure_layout(comm)
        # Windows retrouve RAGO-LIB hors ligne par son PARTUUID (partition.json) :
        # noté aussi ici, pas seulement au montage (sinon un premier usage sans
        # montage laisserait Windows chercher par l'étiquette, illisible hors ligne).
        if partuuid and serial and valid_partuuid(partuuid) and valid_serial(serial):
            record_partition(comm, partuuid, serial)
        write_json(comm.path("library", "requests", req["id"] + ".json"), req)
        # Une nouvelle demande remplace le résultat d'une précédente identique.
        old = comm.path("library", "results", req["id"] + ".json")
        if os.path.exists(old):
            os.remove(old)
            fsync_dir(os.path.dirname(old))
    print(f"requête {req['id']} écrite dans RAGO-COMM : traitée au prochain démarrage du micro-Windows")
    return 0


def check_req_id(rid):
    if not REQ_ID_RE.fullmatch(rid or ""):
        raise Refused(f"identifiant de requête {rid!r} invalide")


def cmd_cancel(conf, rid):
    check_req_id(rid)
    with Comm(conf) as comm:
        p = comm.path("library", "requests", rid + ".json")
        if not os.path.exists(p):
            raise Failed(f"pas de requête en attente {rid}")
        os.remove(p)
        fsync_dir(os.path.dirname(p))
    print(f"requête {rid} annulée (si Windows l'avait déjà commencée, voir son résultat)")
    return 0


def cmd_forget(conf, rid):
    check_req_id(rid)
    with Comm(conf) as comm:
        p = comm.path("library", "results", rid + ".json")
        res = read_json(p)
        if res is None:
            raise Failed(f"pas de résultat {rid}")
        if res.get("state") not in FINISHED:
            raise Refused(f"requête {rid} pas finie ({res.get('state')!r}) : rien effacé")
        os.remove(p)
        fsync_dir(os.path.dirname(p))
    print(f"résultat {rid} effacé")
    return 0


def cmd_record_partition(conf, partuuid, serial):
    if not valid_partuuid(partuuid):
        raise Refused(f"PARTUUID {partuuid!r} invalide (partition GPT attendue)")
    if not valid_serial(serial):
        raise Refused(f"numéro de série NTFS {serial!r} invalide")
    with Comm(conf) as comm:
        ensure_layout(comm)
        done = record_partition(comm, partuuid, serial)
    print("partition RAGO-LIB notée pour Windows (library/partition.json)" if done
          else "partition RAGO-LIB déjà connue de Windows (library/partition.json)")
    return 0


# --- lecture : état, requêtes, jeux ----------------------------------------------------------

def read_dir_json(d, kind):
    out = []
    if not os.path.isdir(d):
        return out
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        obj = read_json(os.path.join(d, name))
        if obj is None:
            continue
        if "_erreur" not in obj and obj.get("kind") != kind:
            obj = {"_erreur": f"{name} : type {obj.get('kind')!r}, {kind} attendu"}
        obj.setdefault("_file", name)
        out.append(obj)
    return out


def comm_snapshot(comm):
    data = read_bytes(comm.path("library", "windows-state.json"))
    confirm = read_json(comm.path("library", "linux-confirm.json"))
    ok, why = decide_from(data, confirm)
    return {
        "windows_state": parse_json(data, "windows-state.json"),
        "rw_allowed": ok,
        "rw_reason": why,
        "partition": read_json(comm.path("library", "partition.json")),
        "requests": read_dir_json(comm.path("library", "requests"), "rago-library-request"),
        "results": read_dir_json(comm.path("library", "results"), "rago-library-result"),
    }


STATE_WORDS = {"pending": "en attente", "waiting_user": "attend le joueur (fenêtre du client)",
               "running": "en cours", "done": "fini", "failed": "échec", "cancelled": "annulée"}


def clean_text(s):
    """Texte pour le terminal : sans caractères de contrôle (noms et messages écrits par
    Windows ou un client : pas de séquence d'échappement envoyée au terminal)."""
    return "".join(c for c in s if c == "\n" or (ord(c) >= 32 and not 0x7F <= ord(c) < 0xA0))


def text_status(snap):
    lines = []
    st = snap.get("windows_state")
    if st is None:
        lines.append("Windows : aucun état écrit (agent M7 jamais démarré)")
    elif "_erreur" in st:
        lines.append(f"Windows : état illisible ({st['_erreur']})")
    else:
        lib = st.get("lib") if isinstance(st.get("lib"), dict) else {}
        lines.append(f"Windows : {st.get('state')} (écrit le {st.get('updated_at', '?')}, démarrage {st.get('boot_id', '?')})"
                     + (f" ; RAGO-LIB hors ligne côté Windows : {'oui' if lib.get('offline') else 'non'}" if lib else ""))
    lines.append(("Écriture sur RAGO-LIB : permise par RAGO-COMM — " if snap.get("rw_allowed")
                  else "Écriture sur RAGO-LIB : NON (lecture seule) — ") + str(snap.get("rw_reason")))
    part = snap.get("partition")
    if isinstance(part, dict) and "_erreur" not in part:
        lines.append(f"Partition notée pour Windows : PARTUUID {part.get('partuuid')}, série NTFS {part.get('ntfs_serial')}")
    else:
        lines.append("Partition pas encore notée pour Windows (monter RAGO-LIB une fois : rago-library mount)")
    reqs = snap.get("requests") or []
    lines.append(f"Requêtes en attente du micro-Windows : {len(reqs)}")
    for r in reqs:
        if "_erreur" in r:
            lines.append(f"  ! {r['_erreur']}")
        else:
            lines.append(f"  {r.get('id')}  ({r.get('name') or r.get('launcher_id')}, écrite le {r.get('written_at')})")
    res = snap.get("results") or []
    if res:
        lines.append("Résultats écrits par Windows :")
    for r in res:
        if "_erreur" in r:
            lines.append(f"  ! {r['_erreur']}")
            continue
        state = r.get("state")
        msg = r.get("message") or ""
        lines.append(f"  {r.get('id')}  {STATE_WORDS.get(state, state)}  {r.get('updated_at', '')}" + (f"  — {msg}" if msg else ""))
    return clean_text("\n".join(lines))


def cmd_status(conf, text):
    with Comm(conf) as comm:
        out = comm_snapshot(comm)
    print(text_status(out) if text else json.dumps(out, indent=2, ensure_ascii=False))
    return 0


def read_games(lib_dir):
    """Jeux décrits par l'agent Windows dans RAGO-LIB/.rago/games/."""
    games = []
    d = os.path.join(lib_dir, ".rago", "games")
    for g in read_dir_json(d, "rago-library-game"):
        if "_erreur" in g:
            games.append(g)
            continue
        key = g.get("key")
        if not isinstance(key, str) or not KEY_RE.fullmatch(key) or g.get("_file") != key + ".json":
            games.append({"_erreur": f"{g.get('_file')} : clé de jeu invalide", "_file": g.get("_file")})
            continue
        rel = g.get("install_dir")
        if isinstance(rel, str):
            # Chemin relatif à la racine de RAGO-LIB, séparateurs « / ».
            norm = os.path.normpath(rel.replace("\\", "/"))
            g["install_dir_present"] = (not os.path.isabs(norm) and not norm.startswith("..")
                                        and isdir_nocase(lib_dir, norm))
        games.append(g)
    return games


def isdir_nocase(base, rel):
    """Dossier présent sous base, casse ignorée comme sous Windows (le client écrit le
    nom de son manifeste, pas forcément la casse réelle ; ntfs3 respecte la casse)."""
    cur = base
    for part in rel.split("/"):
        if part in ("", "."):
            continue
        nxt = os.path.join(cur, part)
        if not os.path.isdir(nxt):
            try:
                names = [n for n in os.listdir(cur) if n.casefold() == part.casefold()]
            except OSError:
                return False
            names = [n for n in names if os.path.isdir(os.path.join(cur, n))]
            if len(names) != 1:
                return False
            nxt = os.path.join(cur, names[0])
        cur = nxt
    return os.path.isdir(cur)


def text_list(out):
    lines = []
    if out.get("lib_dir"):
        lib = out.get("library")
        mode = out.get("lib_mode") or "?"
        if lib is None:
            lines.append(f"RAGO-LIB ({out['lib_dir']}, {mode}) : pas encore préparée (.rago/library.json absent)")
        else:
            lines.append(f"RAGO-LIB ({out['lib_dir']}, {mode})")
        games = out.get("games") or []
        if not games:
            lines.append("  aucun jeu installé par le micro-Windows")
        for g in games:
            if "_erreur" in g:
                lines.append(f"  ! {g['_erreur']}")
                continue
            where = g.get("install_dir") or "?"
            state = "installé" if g.get("installed") else "pas installé"
            if g.get("installed") and g.get("install_dir_present") is False:
                state = "installé d'après Windows, dossier ABSENT"
            lines.append(f"  {g.get('key'):<28} {(g.get('name') or g.get('launcher_id') or ''):<32} {state:<12} {where}")
    else:
        lines.append("RAGO-LIB non lue")
    if "comm_error" in out:
        lines.append(f"RAGO-COMM : {out['comm_error']}")
    else:
        lines.append(text_status(out))
    return clean_text("\n".join(lines))


def cmd_list(conf, lib_dir, text, lib_mode=None):
    out = {"library": None, "games": [], "lib_dir": None if lib_dir == "-" else lib_dir, "lib_mode": lib_mode}
    if lib_dir != "-":
        out["library"] = read_json(os.path.join(lib_dir, ".rago", "library.json"))
        out["games"] = read_games(lib_dir)
    try:
        with Comm(conf) as comm:
            snap = comm_snapshot(comm)
        out.update(snap)
    except Failed as e:
        out["comm_error"] = str(e)
    print(text_list(out) if text else json.dumps(out, indent=2, ensure_ascii=False))
    return 0


def cmd_init(lib_dir):
    if not os.path.isdir(lib_dir):
        raise Failed(f"{lib_dir} : RAGO-LIB n'est pas montée")
    if not os.access(lib_dir, os.W_OK):
        raise Failed(f"{lib_dir} : RAGO-LIB n'est pas montée en écriture")
    made = []
    for d in (".rago", os.path.join(".rago", "games"), os.path.join(".rago", "cache"),
              "Games", os.path.join("Games", "Steam"), os.path.join("Games", "Epic"),
              os.path.join("Games", "Riot")):
        p = os.path.join(lib_dir, d)
        if not os.path.isdir(p):
            os.makedirs(p, exist_ok=True)
            made.append(d)
    lj = os.path.join(lib_dir, ".rago", "library.json")
    if read_json(lj) is None:
        write_json(lj, {"schema": 1, "kind": "rago-library", "layout": 1, "label": "RAGO-LIB",
                        "created_at": utc_now(), "writer": WRITER,
                        "doc": "Bibliotheque de jeux Windows de Rago OS (M7). Jeux installes par les "
                               "clients officiels dans le micro-Windows. Jamais ouverte par Linux et "
                               "Windows en meme temps."}, mode=0o644)
        made.append(".rago/library.json")
    print("RAGO-LIB prête" + (f" (créé : {', '.join(made)})" if made else " (rien à créer)"))
    return 0


USAGE = """usage : rago_library.py decide | confirm-off | status [--text]
       rago_library.py prepare-mount PÉRIPH auto|rw|ro [PARTUUID NUMÉRO|- -] [--no-ntfs]
       rago_library.py ntfs-check PÉRIPH | claimed PÉRIPH...
       rago_library.py request install|launch steam|epic|riot ID [--name NOM] [--partuuid P --serial N]
       rago_library.py cancel ID | forget ID
       rago_library.py record-partition PARTUUID NUMÉRO_DE_SÉRIE
       rago_library.py list DOSSIER_RAGO_LIB|- [--text] [--mode MODE] | init DOSSIER_RAGO_LIB
(appelé par rago-library ; réglages de RAGO-COMM : /etc/rago/rago-comm.conf)"""


def pop_flag(args, flag):
    if flag in args:
        args.remove(flag)
        return True
    return False


def pop_opt(args, opt):
    if opt in args:
        i = args.index(opt)
        if i + 1 >= len(args):
            raise Refused(f"{opt} sans valeur")
        v = args[i + 1]
        del args[i:i + 2]
        return v
    return None


def main(argv, env):
    args = list(argv[1:])
    if not args or args[0] in ("-h", "--help"):
        print(USAGE, file=sys.stdout if args else sys.stderr)
        return 0 if args else 2
    try:
        cmd = args.pop(0)
        if cmd == "init":
            if len(args) != 1:
                raise Refused("init DOSSIER")
            return cmd_init(args[0])
        if cmd == "ntfs-check":
            if len(args) != 1:
                raise Refused("ntfs-check PÉRIPHÉRIQUE")
            return cmd_ntfs_check(args[0])
        if cmd == "claimed":
            if not args:
                raise Refused("claimed PÉRIPHÉRIQUE...")
            return cmd_claimed(args)
        # RAGO_COMM_CONF : seulement pour les tests.
        conf = load_conf(env.get("RAGO_COMM_CONF", CONF_DEFAULT))
        if cmd == "decide" and not args:
            return cmd_decide(conf)
        if cmd == "status":
            text = pop_flag(args, "--text")
            if not args:
                return cmd_status(conf, text)
        if cmd == "confirm-off" and not args:
            return cmd_confirm_off(conf)
        if cmd == "prepare-mount":
            check_ntfs = not pop_flag(args, "--no-ntfs")
            if len(args) in (2, 4):
                pu = args[2] if len(args) == 4 and args[2] != "-" else None
                se = args[3] if len(args) == 4 and args[3] != "-" else None
                return cmd_prepare_mount(conf, args[0], args[1], pu, se, check_ntfs)
        if cmd == "request":
            name = pop_opt(args, "--name")
            pu = pop_opt(args, "--partuuid")
            se = pop_opt(args, "--serial")
            if len(args) == 3:
                return cmd_request(conf, args[0], args[1], args[2], name, pu, se)
        if cmd == "cancel" and len(args) == 1:
            return cmd_cancel(conf, args[0])
        if cmd == "forget" and len(args) == 1:
            return cmd_forget(conf, args[0])
        if cmd == "record-partition" and len(args) == 2:
            return cmd_record_partition(conf, args[0], args[1])
        if cmd == "list":
            text = pop_flag(args, "--text")
            mode = pop_opt(args, "--mode")
            if len(args) == 1:
                return cmd_list(conf, args[0], text, mode)
        print(USAGE, file=sys.stderr)
        return 2
    except Refused as e:
        log(f"refusé : {e}")
        return 2
    except Failed as e:
        log(f"erreur : {e}")
        return 1
    except OSError as e:
        log(f"erreur : {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv, os.environ))
