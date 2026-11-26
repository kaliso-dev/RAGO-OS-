#!/usr/bin/env python3
"""Outils Rago Hub pour les fils (Claude Code).

Usage : python3 hub.py [--fil HUB-xxxxxx] <commande> [arguments]

  fils                         état de tous les fils du projet
  lire HUB-xxxxxx [n]          derniers messages d'un fil
  envoyer HUB-xxxxxx "texte"   confier une info ou une tâche à un autre fil
  chef "texte"                 écrire dans la conversation principale
  memoire                      instructions et mémoire commune du projet
  retenir "fait"               ajouter un fait à la mémoire commune
  fichiers                     fichiers du projet et pièces jointes
  telecharger <id> [dossier]   récupérer un fichier (dossier par défaut : ./hub-files)
  donner <chemin> ["note"]     donner un fichier téléchargeable aux humains
  resolu "résumé"              marquer ce fil résolu (après validation humaine)

Le texte peut aussi être passé sur l'entrée standard (ex. : echo "..." | hub.py chef -).
"""
import json
import os
import re
import sys
import urllib.parse
import urllib.request

URL = (os.environ.get("HUB_URL") or os.environ.get("RAGO_HUB_URL") or "").rstrip("/")
TOKEN = os.environ.get("HUB_TOKEN") or os.environ.get("RAGO_HUB_TOKEN") or ""
FIL = os.environ.get("HUB_FIL") or ""


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def request(method, path, params=None, body=None, raw=None, headers=None, timeout=60):
    q = dict(params or {})
    q["fil"] = FIL
    url = URL + path + "?" + urllib.parse.urlencode(q)
    h = {"Authorization": "Bearer " + TOKEN}
    data = None
    if raw is not None:
        data = raw
        h["Content-Type"] = "application/octet-stream"
    elif body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read(), r.headers
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read()).get("error")
        except Exception:
            msg = str(e)
        die(f"Rago Hub : {msg}")
    except Exception as e:
        die(f"Rago Hub injoignable : {e}")


def text_arg(args, i):
    if len(args) <= i:
        die("texte manquant")
    t = " ".join(args[i:])
    if t == "-":
        t = sys.stdin.read()
    if not t.strip():
        die("texte vide")
    return t


def show(resp):
    body, _ = resp
    try:
        obj = json.loads(body)
    except Exception:
        print(body.decode(errors="replace"))
        return
    print(obj.get("text") or json.dumps(obj, ensure_ascii=False, indent=2))


def main():
    global FIL
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == "--fil":
        FIL = args[1]
        args = args[2:]
    if not args or args[0] in ("-h", "--help", "aide"):
        print(__doc__)
        return
    if not URL or not TOKEN:
        die("Rago Hub n'est pas configuré dans cet environnement (HUB_URL / RAGO_HUB_URL manquant).")
    if not re.fullmatch(r"HUB-[0-9a-f]{6}", FIL or ""):
        die("Indique ton fil : hub.py --fil HUB-xxxxxx <commande>")
    cmd = args[0]
    if cmd == "fils":
        show(request("GET", "/api/hook/threads"))
    elif cmd == "lire":
        if len(args) < 2:
            die("usage : lire HUB-xxxxxx [n]")
        show(request("GET", "/api/hook/thread/" + args[1], {"n": args[2] if len(args) > 2 else "8"}))
    elif cmd == "envoyer":
        if len(args) < 3:
            die('usage : envoyer HUB-xxxxxx "texte"')
        show(request("POST", "/api/hook/send", body={"to": args[1], "text": text_arg(args, 2)}))
    elif cmd == "chef":
        show(request("POST", "/api/hook/chef", body={"text": text_arg(args, 1)}))
    elif cmd == "memoire":
        show(request("GET", "/api/hook/memory"))
    elif cmd == "retenir":
        show(request("POST", "/api/hook/remember", body={"text": text_arg(args, 1)}))
    elif cmd == "fichiers":
        show(request("GET", "/api/hook/files"))
    elif cmd == "telecharger":
        if len(args) < 2:
            die("usage : telecharger <id> [dossier]")
        dest = args[2] if len(args) > 2 else "hub-files"
        body, headers = request("GET", "/api/hook/download/" + args[1], timeout=300)
        name = urllib.parse.unquote(headers.get("X-Hub-Name") or args[1])
        name = os.path.basename(name) or args[1]
        os.makedirs(dest, exist_ok=True)
        path = os.path.join(dest, name)
        with open(path, "wb") as f:
            f.write(body)
        print(f"Fichier enregistré : {os.path.abspath(path)} ({len(body)} octets)")
    elif cmd == "donner":
        if len(args) < 2:
            die('usage : donner <chemin> ["note"]')
        p = args[1]
        if not os.path.isfile(p):
            die(f"fichier introuvable : {p}")
        size = os.path.getsize(p)
        if size > 50 * 1024 * 1024:
            die("fichier trop gros (50 Mo maximum)")
        with open(p, "rb") as f:
            data = f.read()
        note = " ".join(args[2:]) if len(args) > 2 else ""
        show(request("POST", "/api/hook/upload", {"name": os.path.basename(p), "note": note}, raw=data, timeout=300))
    elif cmd == "resolu":
        show(request("POST", "/api/hook/resolve", body={"summary": " ".join(args[1:])}))
    else:
        die(f"commande inconnue : {cmd}\n\n{__doc__}")


if __name__ == "__main__":
    main()
