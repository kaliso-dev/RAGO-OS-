#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — branche le hook rago-launch dans Steam, Heroic et Lutris (module M2).
# Marqueur : rago-proton-layer
#
# Steam n'a pas d'option de lancement globale : on écrit « rago-launch
# %command% » dans les options de lancement de chaque jeu installé
# (userdata/<id>/config/localconfig.vdf), Steam FERMÉ (il réécrit ce fichier en
# quittant). La session Rago le fait avant de démarrer Steam ; un jeu installé
# en cours de session est branché à la session suivante.
#
#   - option existante « PROTON_LOG=1 %command% -novid »
#       -> « PROTON_LOG=1 rago-launch %command% -novid » ;
#   - option sans %command% (« -novid ») -> « rago-launch %command% -novid » ;
#   - un hook retiré à la main par le joueur n'est jamais remis (choix noté) ;
#   - unsync remet l'option d'origine.
# Outil Steam par défaut (« Proton » pour tous les jeux Windows) : le Proton-GE
# épinglé, seulement si le joueur n'en a pas choisi un (config/config.vdf).
#
# Usage : rago-steam-config <commande> [options]
#   sync      branche Steam (+ outil par défaut, + chemins des runtimes EAC/BattlEye)
#   unsync    retire tout ce que sync a posé
#   status    ce qui est branché
#   heroic    enveloppe globale rago-launch dans Heroic (--remove pour retirer)
#   lutris    préfixe de commande rago-launch dans Lutris (--remove pour retirer)
#   runtimes  chemins des runtimes Proton EasyAntiCheat / BattlEye installés
# Options : --steam-root DIR, --hook CMD (défaut rago-launch),
#           --default-tool NOM | --no-default-tool, --dry-run, --json (status)
# Codes : 0 = fait, 2 = usage, 3 = Steam / Heroic / Lutris introuvable,
#         5 = le programme tourne (rien écrit : le fermer d'abord).

import argparse
import json
import os
import re
import sys

MARKER = "rago-proton-layer"
DEFAULT_HOOK = "rago-launch"
# Outils Steam (pas des jeux) : pas d'option de lancement.
TOOL_APPIDS = {
    "228980",   # Steamworks Common Redistributables
    "1070560",  # Steam Linux Runtime 1.0 (scout)
    "1391110",  # Steam Linux Runtime 2.0 (soldier)
    "1628350",  # Steam Linux Runtime 3.0 (sniper)
    "1826330",  # Proton EasyAntiCheat Runtime
    "1161040",  # Proton BattlEye Runtime
    "1493710",  # Proton Experimental
    "1580130",  # Proton 6.3
    "1887720",  # Proton 7.0
    "2348590",  # Proton 8.0
    "2805730",  # Proton 9.0
    "2180100",  # Proton Hotfix
}
TOOL_NAME_RE = re.compile(r"^(Proton\b|Steam Linux Runtime|Steamworks Common|SteamVR\b)", re.I)
RUNTIMES = {
    "PROTON_EAC_RUNTIME": ("1826330", "Proton EasyAntiCheat Runtime"),
    "PROTON_BATTLEYE_RUNTIME": ("1161040", "Proton BattlEye Runtime"),
}
EXIT_MISSING = 3
EXIT_RUNNING = 5


# --- VDF (KeyValues texte de Valve) -------------------------------------------------------
# Un nœud = liste de [clé, valeur, condition] ; valeur = str ou nœud. L'ordre
# et les doublons sont gardés, les clés se cherchent sans tenir compte de la
# casse (comme Steam).

class VdfError(ValueError):
    pass


def _tokens(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
        elif c in "{}":
            yield c
            i += 1
        elif c == '"':
            i += 1
            buf = []
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    e = text[i + 1]
                    buf.append({"n": "\n", "t": "\t", "\\": "\\", '"': '"'}.get(e, "\\" + e))
                    i += 2
                else:
                    buf.append(text[i])
                    i += 1
            if i >= n:
                raise VdfError("guillemet non fermé")
            i += 1
            yield ("s", "".join(buf))
        else:
            j = i
            while j < n and text[j] not in ' \t\r\n{}"':
                j += 1
            yield ("s", text[i:j])
            i = j


def vdf_loads(text):
    stack = [[]]
    key = None
    pending = None  # [clé, valeur, condition] qui peut recevoir une condition
    for t in _tokens(text):
        if t == "{":
            if key is None:
                raise VdfError("« { » sans clé")
            node = []
            pair = [key, node, None]
            stack[-1].append(pair)
            stack.append(node)
            key, pending = None, pair
        elif t == "}":
            if key is not None or len(stack) == 1:
                raise VdfError("« } » inattendue")
            stack.pop()
            pending = None
        else:
            s = t[1]
            if key is None:
                if pending is not None and s.startswith("[") and s.endswith("]"):
                    pending[2] = s
                    pending = None
                    continue
                key = s
            else:
                pair = [key, s, None]
                stack[-1].append(pair)
                key, pending = None, pair
    if key is not None or len(stack) != 1:
        raise VdfError("fichier VDF tronqué")
    return stack[0]


def _q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def vdf_dumps(node, depth=0):
    out = []
    ind = "\t" * depth
    for k, v, cond in node:
        c = " " + cond if cond else ""
        if isinstance(v, list):
            out.append(f"{ind}{_q(k)}{c}\n{ind}{{\n")
            out.append(vdf_dumps(v, depth + 1))
            out.append(f"{ind}}}\n")
        else:
            out.append(f"{ind}{_q(k)}\t\t{_q(v)}{c}\n")
    return "".join(out)


def vdf_get(node, key):
    lk = key.lower()
    for pair in node:
        if pair[0].lower() == lk:
            return pair[1]
    return None


def vdf_child(node, key, create=False):
    """Sous-nœud <key> (créé si absent et create=True)."""
    v = vdf_get(node, key)
    if isinstance(v, list):
        return v
    if not create:
        return None
    new = []
    node.append([key, new, None])
    return new


def vdf_path(node, keys, create=False):
    for k in keys:
        node = vdf_child(node, k, create)
        if node is None:
            return None
    return node


def vdf_set(node, key, value):
    lk = key.lower()
    for pair in node:
        if pair[0].lower() == lk:
            pair[1] = value
            return
    node.append([key, value, None])


def vdf_del(node, key):
    lk = key.lower()
    node[:] = [p for p in node if p[0].lower() != lk]


def read_text(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write_atomic(path, text, backup=True):
    if backup and os.path.exists(path):
        b = path + ".rago-bak"
        if not os.path.exists(b):
            with open(b, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(read_text(path))
    tmp = f"{path}.rago-tmp"
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text)
    try:
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    except FileNotFoundError:
        pass
    os.replace(tmp, path)


# --- options de lancement -----------------------------------------------------------------

def _hook_re(cmd):
    base = re.escape(os.path.basename(cmd))
    return re.compile(r"(?<!\S)(\S*/)?" + base + r"(?!\S)")


def has_hook(opts, cmd=DEFAULT_HOOK):
    return bool(_hook_re(cmd).search(opts or ""))


def hook_options(opts, cmd=DEFAULT_HOOK):
    """Option de lancement avec le hook, au plus près de la commande du jeu."""
    opts = opts or ""
    if has_hook(opts, cmd):
        return opts
    s = opts.strip()
    if not s:
        return f"{cmd} %command%"
    if "%command%" in s:
        return s.replace("%command%", f"{cmd} %command%", 1)
    # Sans %command%, Steam ajoute ces mots à la fin de la commande du jeu.
    return f"{cmd} %command% {s}"


def unhook_options(opts, cmd=DEFAULT_HOOK):
    opts = opts or ""
    r = _hook_re(cmd)
    m = r.search(opts)
    if not m:
        return opts
    s = (opts[: m.start()] + opts[m.end():].lstrip()).strip()
    s = re.sub(r"[ \t]{2,}", " ", s)
    return "" if s == "%command%" else s


# --- Steam ----------------------------------------------------------------------------------

def steam_root(explicit=None, home=None):
    if explicit:
        return os.path.realpath(explicit) if os.path.isdir(explicit) else None
    home = home or os.path.expanduser("~")
    for d in (".steam/root", ".local/share/Steam", ".steam/debian-installation", ".steam/steam"):
        p = os.path.join(home, d)
        if any(os.path.exists(os.path.join(p, x)) for x in ("steamapps", "steam.sh", "ubuntu12_32")):
            return os.path.realpath(p)
    return None


def libraries(root):
    libs = [root]
    f = os.path.join(root, "steamapps", "libraryfolders.vdf")
    try:
        lf = vdf_get(vdf_loads(read_text(f)), "libraryfolders")
    except (OSError, VdfError):
        lf = None
    if isinstance(lf, list):
        for k, v, _ in lf:
            if not k.isdigit():
                continue
            p = vdf_get(v, "path") if isinstance(v, list) else v
            if isinstance(p, str) and p and os.path.realpath(p) not in [os.path.realpath(x) for x in libs]:
                libs.append(p)
    return libs


def installed_apps(root):
    """{appid: (nom, dossier d'installation, bibliothèque)} des applications installées."""
    apps = {}
    for lib in libraries(root):
        d = os.path.join(lib, "steamapps")
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for fn in names:
            if not (fn.startswith("appmanifest_") and fn.endswith(".acf")):
                continue
            try:
                st = vdf_get(vdf_loads(read_text(os.path.join(d, fn))), "AppState")
            except (OSError, VdfError):
                continue
            if not isinstance(st, list):
                continue
            appid = vdf_get(st, "appid") or fn[12:-4]
            apps[str(appid)] = (vdf_get(st, "name") or "", vdf_get(st, "installdir") or "", lib)
    return apps


def is_tool(appid, name):
    return appid in TOOL_APPIDS or bool(TOOL_NAME_RE.match(name or ""))


def steam_users(root):
    ud = os.path.join(root, "userdata")
    try:
        ids = sorted(os.listdir(ud))
    except OSError:
        return []
    out = []
    for i in ids:
        if i.isdigit() and i != "0":
            f = os.path.join(ud, i, "config", "localconfig.vdf")
            if os.path.isfile(f):
                out.append((i, f))
    return out


def running(names, procfs="/proc"):
    """PID d'un processus de cet utilisateur dont le nom est dans <names>, ou None."""
    uid = os.getuid()
    try:
        pids = [p for p in os.listdir(procfs) if p.isdigit()]
    except OSError:
        return None
    for p in pids:
        try:
            with open(os.path.join(procfs, p, "comm")) as f:
                comm = f.read().strip()
            if comm in names and os.stat(os.path.join(procfs, p)).st_uid == uid:
                return int(p)
        except OSError:
            continue
    return None


def state_path():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "rago", "steam-hook.json")


def load_state(path):
    try:
        with open(path) as f:
            st = json.load(f)
        if isinstance(st, dict):
            st.setdefault("users", {})
            st.setdefault("compat", {})
            st.setdefault("heroic", {})
            st.setdefault("lutris", {})
            return st
    except (OSError, ValueError):
        pass
    return {"marker": MARKER, "users": {}, "compat": {}, "heroic": {}, "lutris": {}}


def save_state(path, st, dry_run):
    if dry_run:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


APPS_PATH = ("UserLocalConfigStore", "Software", "Valve", "Steam", "apps")
COMPAT_PATH = ("InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping")


def sync_user(localconfig, apps, ust, cmd, dry_run, log):
    """Branche les jeux d'un compte Steam. Renvoie (branchés, refus, inchangés)."""
    tree = vdf_loads(read_text(localconfig))
    if not tree:
        tree.append(["UserLocalConfigStore", [], None])
    appsnode = vdf_path(tree, APPS_PATH, create=True)
    hooked = ust.setdefault("hooked", {})
    optout = ust.setdefault("optout", [])
    n_new = n_opt = n_same = 0
    changed = False
    for appid in sorted(apps, key=lambda a: int(a) if a.isdigit() else 0):
        name = apps[appid][0]
        if is_tool(appid, name):
            continue
        if appid in optout:
            n_opt += 1
            continue
        node = vdf_child(appsnode, appid)
        cur = (vdf_get(node, "LaunchOptions") if node is not None else None) or ""
        if appid in hooked and not has_hook(cur, cmd):
            # Le joueur a retiré le hook : on respecte, pour toujours.
            log(f"  {appid} {name} : hook retiré à la main, laissé ainsi")
            optout.append(appid)
            del hooked[appid]
            n_opt += 1
            continue
        if has_hook(cur, cmd):
            n_same += 1
            continue
        new = hook_options(cur, cmd)
        if node is None:
            node = vdf_child(appsnode, appid, create=True)
        vdf_set(node, "LaunchOptions", new)
        hooked[appid] = {"original": cur, "written": new}
        changed = True
        n_new += 1
        log(f"  {appid} {name} : « {new} »")
    if changed and not dry_run:
        write_atomic(localconfig, vdf_dumps(tree))
    return n_new, n_opt, n_same


def unsync_user(localconfig, ust, cmd, dry_run, log):
    tree = vdf_loads(read_text(localconfig))
    appsnode = vdf_path(tree, APPS_PATH)
    hooked = ust.get("hooked", {})
    n = 0
    changed = False
    if appsnode is not None:
        for appid, rec in list(hooked.items()):
            node = vdf_child(appsnode, appid)
            if node is None:
                continue
            cur = vdf_get(node, "LaunchOptions") or ""
            if not has_hook(cur, cmd):
                continue
            new = rec.get("original", "") if cur == rec.get("written") else unhook_options(cur, cmd)
            vdf_set(node, "LaunchOptions", new)
            changed = True
            n += 1
            log(f"  {appid} : « {new} »")
    if changed and not dry_run:
        write_atomic(localconfig, vdf_dumps(tree))
    ust["hooked"] = {}
    return n


def sync_compat(root, tool, cst, dry_run, log):
    """Outil de compatibilité par défaut. Renvoie un message."""
    f = os.path.join(root, "config", "config.vdf")
    if not os.path.isfile(f):
        return "config.vdf absent (Steam jamais démarré) : outil par défaut à la prochaine session"
    tree = vdf_loads(read_text(f))
    mapping = vdf_path(tree, COMPAT_PATH, create=True)
    cur_node = vdf_child(mapping, "0")
    cur = vdf_get(cur_node, "name") if cur_node is not None else None
    ours = cst.get("value")
    if cur and cur != ours:
        cst.pop("value", None)
        return f"outil par défaut choisi par le joueur ({cur}) : gardé"
    if cur == tool:
        return f"outil par défaut : {tool}"
    node = vdf_child(mapping, "0", create=True)
    vdf_set(node, "name", tool)
    vdf_set(node, "config", "")
    vdf_set(node, "priority", "75")
    cst["value"] = tool
    if not dry_run:
        write_atomic(f, vdf_dumps(tree))
    return f"outil par défaut : {tool} (avant : {cur or 'Proton de Valve'})"


def unsync_compat(root, cst, dry_run):
    f = os.path.join(root, "config", "config.vdf")
    ours = cst.pop("value", None)
    if not ours or not os.path.isfile(f):
        return None
    tree = vdf_loads(read_text(f))
    mapping = vdf_path(tree, COMPAT_PATH)
    node = vdf_child(mapping, "0") if mapping is not None else None
    if node is None or vdf_get(node, "name") != ours:
        return None
    vdf_del(mapping, "0")
    if not dry_run:
        write_atomic(f, vdf_dumps(tree))
    return ours


def find_runtimes(root, apps=None):
    apps = installed_apps(root) if apps is None else apps
    out = {}
    for var, (appid, name) in RUNTIMES.items():
        cands = []
        if appid in apps:
            _, inst, lib = apps[appid]
            cands.append(os.path.join(lib, "steamapps", "common", inst or name))
        cands += [os.path.join(lib, "steamapps", "common", name) for lib in libraries(root)]
        for c in cands:
            if os.path.isdir(c):
                out[var] = c
                break
    return out


def write_runtimes_env(found, dry_run):
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    f = os.path.join(base, "rago", "proton-runtimes.env")
    text = f"# Rago OS — runtimes Proton anti-triche trouvés par rago-steam-config ({MARKER})\n"
    for k in sorted(found):
        text += f'{k}="{found[k]}"\n'
    if not dry_run:
        os.makedirs(os.path.dirname(f), exist_ok=True)
        write_atomic(f, text, backup=False)
    return f


# --- Heroic ---------------------------------------------------------------------------------

def heroic_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "heroic")


def _wrap_add(settings, exe):
    w = settings.get("wrapperOptions")
    if not isinstance(w, list):
        w = []
    if any(isinstance(x, dict) and os.path.basename(str(x.get("exe", ""))) == os.path.basename(exe) for x in w):
        return False
    # En premier : le hook enveloppe les autres enveloppes de Heroic.
    settings["wrapperOptions"] = [{"exe": exe, "args": ""}] + w
    return True


def _wrap_remove(settings, exe):
    w = settings.get("wrapperOptions")
    if not isinstance(w, list):
        return False
    keep = [x for x in w if not (isinstance(x, dict) and os.path.basename(str(x.get("exe", ""))) == os.path.basename(exe))]
    if len(keep) == len(w):
        return False
    settings["wrapperOptions"] = keep
    return True


def heroic(exe, remove, dry_run, log):
    d = heroic_dir()
    main = os.path.join(d, "config.json")
    if not os.path.isfile(main):
        log(f"Heroic : {main} absent (Heroic jamais démarré)")
        return EXIT_MISSING
    if running({"heroic", "Heroic"}):
        log("Heroic tourne : le fermer d'abord (il réécrit sa configuration)")
        return EXIT_RUNNING
    files = [(main, "defaultSettings")]
    gc = os.path.join(d, "GamesConfig")
    if os.path.isdir(gc):
        files += [(os.path.join(gc, f), None) for f in sorted(os.listdir(gc)) if f.endswith(".json")]
    n = 0
    for path, key in files:
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, ValueError) as e:
            log(f"Heroic : {path} illisible ({e}) : sauté")
            continue
        if not isinstance(data, dict):
            continue
        targets = []
        if key:
            data.setdefault(key, {})
            targets.append(data[key])
        else:
            targets += [v for k, v in data.items() if isinstance(v, dict) and k not in ("version", "explicit")]
        changed = False
        for t in targets:
            changed |= (_wrap_remove if remove else _wrap_add)(t, exe)
        if changed:
            n += 1
            if not dry_run:
                write_atomic(path, json.dumps(data, indent=2) + "\n")
    log(f"Heroic : enveloppe {exe} {'retirée de' if remove else 'ajoutée à'} {n} fichier(s)")
    return 0


# --- Lutris ---------------------------------------------------------------------------------

def lutris(cmd, remove, dry_run, log):
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    f = os.path.join(base, "lutris", "system.yml")
    if not os.path.isdir(os.path.dirname(f)):
        log(f"Lutris : {os.path.dirname(f)} absent (Lutris jamais démarré)")
        return EXIT_MISSING
    if running({"lutris"}):
        log("Lutris tourne : le fermer d'abord")
        return EXIT_RUNNING
    try:
        import yaml  # Lutris en dépend : présent si Lutris est installé
    except ImportError:
        log(f"Lutris : module yaml absent ; à la main : Préférences > Système > Préfixe de commande = {cmd}")
        return EXIT_MISSING
    data = {}
    if os.path.isfile(f):
        with open(f) as fh:
            data = yaml.safe_load(fh) or {}
    system = data.setdefault("system", {}) if isinstance(data, dict) else None
    if system is None or not isinstance(system, dict):
        log(f"Lutris : {f} inattendu : sauté")
        return 1
    cur = str(system.get("prefix_command") or "")
    if remove:
        if not has_hook(cur, cmd):
            return 0
        new = unhook_options(cur, cmd)
        if new:
            system["prefix_command"] = new
        else:
            system.pop("prefix_command", None)
    else:
        if has_hook(cur, cmd):
            log(f"Lutris : préfixe déjà « {cur} »")
            return 0
        system["prefix_command"] = (cmd + " " + cur).strip()
    if not dry_run:
        write_atomic(f, yaml.safe_dump(data, default_flow_style=False))
    log(f"Lutris : préfixe de commande « {system.get('prefix_command', '')} »")
    return 0


# --- commandes ------------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(prog="rago-steam-config", description="Branche rago-launch (Rago OS, M2) dans Steam, Heroic et Lutris.")
    ap.add_argument("command", choices=["sync", "unsync", "status", "heroic", "lutris", "runtimes"])
    ap.add_argument("--steam-root")
    ap.add_argument("--hook", default=DEFAULT_HOOK)
    ap.add_argument("--default-tool", default="")
    ap.add_argument("--no-default-tool", action="store_true")
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args(argv)

    def log(msg):
        if not a.quiet:
            print(msg, file=sys.stderr)

    if a.command == "heroic":
        exe = a.hook if "/" in a.hook else (_which(a.hook) or "/usr/bin/" + a.hook)
        return heroic(exe, a.remove, a.dry_run, log)
    if a.command == "lutris":
        return lutris(a.hook, a.remove, a.dry_run, log)

    root = steam_root(a.steam_root)
    if not root:
        log("Steam introuvable (~/.local/share/Steam, ~/.steam/…) : le démarrer une fois")
        return EXIT_MISSING
    sp = state_path()
    st = load_state(sp)
    ckey = os.path.realpath(root)

    if a.command == "runtimes":
        for k, v in sorted(find_runtimes(root).items()):
            print(f"{k}={v}")
        return 0

    if a.command == "status":
        apps = installed_apps(root)
        games = [x for x in apps if not is_tool(x, apps[x][0])]
        rep = {"steam_root": root, "games": len(games), "users": {}, "runtimes": find_runtimes(root, apps),
               "default_tool": st["compat"].get(ckey, {}).get("value")}
        for uid, lc in steam_users(root):
            try:
                node = vdf_path(vdf_loads(read_text(lc)), APPS_PATH)
            except (OSError, VdfError):
                node = None
            n = sum(1 for x in games if node is not None and has_hook(vdf_get(vdf_child(node, x) or [], "LaunchOptions") or "", a.hook))
            us = st["users"].get(uid, {})
            rep["users"][uid] = {"hooked": n, "not_hooked": len(games) - n, "optout": len(us.get("optout", []))}
        if a.json:
            print(json.dumps(rep, indent=1, sort_keys=True))
        else:
            print(f"Steam : {root} ({rep['games']} jeu(x) installé(s))")
            for uid, r in rep["users"].items():
                print(f"  compte {uid} : {r['hooked']} branché(s), {r['not_hooked']} non branché(s), dont {r['optout']} retiré(s) par le joueur")
            for k, v in sorted(rep["runtimes"].items()):
                print(f"  {k} = {v}")
            for k in RUNTIMES:
                if k not in rep["runtimes"]:
                    print(f"  {RUNTIMES[k][1]} : pas installé (Steam l'installe avec le premier jeu qui en a besoin)")
            if rep["default_tool"]:
                print(f"  outil par défaut posé par Rago : {rep['default_tool']}")
        return 0

    pid = running({"steam"})
    if pid:
        log(f"Steam tourne (PID {pid}) : rien écrit (Steam réécrit sa configuration en quittant). Fermer Steam puis relancer.")
        return EXIT_RUNNING

    if a.command == "sync":
        apps = installed_apps(root)
        users = steam_users(root)
        if not users:
            log("aucun compte Steam (userdata) : se connecter à Steam une fois, puis la session branchera les jeux")
        for uid, lc in users:
            ust = st["users"].setdefault(uid, {})
            try:
                n_new, n_opt, n_same = sync_user(lc, apps, ust, a.hook, a.dry_run, log)
            except (OSError, VdfError) as e:
                log(f"compte {uid} : {lc} illisible ({e}) : sauté")
                continue
            log(f"compte {uid} : {n_new} jeu(x) branché(s), {n_same} déjà, {n_opt} retiré(s) par le joueur")
        if a.default_tool and not a.no_default_tool:
            try:
                log(sync_compat(root, a.default_tool, st["compat"].setdefault(ckey, {}), a.dry_run, log))
            except (OSError, VdfError) as e:
                log(f"config.vdf illisible ({e}) : outil par défaut non posé")
        found = find_runtimes(root, apps)
        f = write_runtimes_env(found, a.dry_run)
        log(f"runtimes anti-triche : {', '.join(sorted(found)) or 'aucun installé'} ({f})")
        save_state(sp, st, a.dry_run)
        return 0

    if a.command == "unsync":
        for uid, lc in steam_users(root):
            ust = st["users"].get(uid)
            if not ust:
                continue
            try:
                n = unsync_user(lc, ust, a.hook, a.dry_run, log)
            except (OSError, VdfError) as e:
                log(f"compte {uid} : {lc} illisible ({e}) : sauté")
                continue
            log(f"compte {uid} : hook retiré de {n} jeu(x)")
        try:
            t = unsync_compat(root, st["compat"].setdefault(ckey, {}), a.dry_run)
            if t:
                log(f"outil par défaut {t} retiré (retour au Proton de Valve)")
        except (OSError, VdfError) as e:
            log(f"config.vdf illisible ({e})")
        save_state(sp, st, a.dry_run)
        return 0
    return 2


def _which(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


if __name__ == "__main__":
    sys.exit(main())
