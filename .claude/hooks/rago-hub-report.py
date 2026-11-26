#!/usr/bin/env python3
"""Hook Claude Code pour Rago Hub (v3).

- PostToolUse : envoie au Hub une ligne d'activité (« lit tel fichier », « lance les tests »…)
  et, si Claude vient d'écrire une image, l'image elle-même.
  Envoie aussi le texte déjà écrit par Claude pendant le tour (affiché « en cours » dans le Hub).
- Stop : envoie la réponse finale du tour et les tokens utilisés.

Ne fait rien si RAGO_HUB_URL / RAGO_HUB_TOKEN ne sont pas définis (sessions normales),
ni si la session n'a pas été lancée par Rago Hub. Ne bloque jamais Claude.
"""
import base64
import json
import os
import re
import sys
import tempfile
import urllib.request

KEY_RE = re.compile(r"\[Rago Hub fil (HUB-[0-9a-f]+)\]")
IMG_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")


def post(url, token, path, payload, timeout=8):
    req = urllib.request.Request(
        url + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + token},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=timeout).read()
    except Exception:
        pass


def texts_of(entry):
    msg = entry.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        return [content], False
    out, has_tool_result = [], False
    if isinstance(content, list):
        for c in content:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "text" and c.get("text"):
                out.append(c["text"])
            elif c.get("type") == "tool_result":
                has_tool_result = True
    return out, has_tool_result


def find_key(data):
    """Clé du fil Rago Hub, mise en cache par session pour ne pas relire le transcript à chaque outil."""
    sid = re.sub(r"[^\w-]", "", str(data.get("session_id") or "x"))
    cache = os.path.join(tempfile.gettempdir(), f"rago-hub-{sid}.key")
    try:
        with open(cache) as f:
            k = f.read().strip()
            return k or None
    except Exception:
        pass
    key = None
    path = data.get("transcript_path")
    if path and os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i > 400:
                    break
                m = KEY_RE.search(line)
                if m:
                    key = m.group(1)
                    break
    try:
        with open(cache, "w") as f:
            f.write(key or "")
    except Exception:
        pass
    return key


def short(s, n=160):
    s = re.sub(r"\s+", " ", str(s or "")).strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def describe_tool(name, inp):
    inp = inp or {}
    p = inp.get("file_path") or inp.get("path") or inp.get("notebook_path")
    rel = os.path.relpath(p, os.environ.get("CLAUDE_PROJECT_DIR", "/")) if p and p.startswith("/") else p
    if name in ("Read",):
        return f"Lit {rel}"
    if name in ("Write",):
        return f"Écrit {rel}"
    if name in ("Edit", "MultiEdit", "NotebookEdit"):
        return f"Modifie {rel}"
    if name == "Bash":
        return "$ " + short(inp.get("description") or inp.get("command"), 140)
    if name in ("Grep",):
        return f"Cherche « {short(inp.get('pattern'), 60)} »"
    if name in ("Glob",):
        return f"Liste {short(inp.get('pattern'), 80)}"
    if name in ("WebFetch",):
        return f"Ouvre {short(inp.get('url'), 100)}"
    if name in ("WebSearch",):
        return f"Recherche web « {short(inp.get('query'), 80)} »"
    if name in ("Agent", "Task"):
        return f"Lance un sous-agent : {short(inp.get('description') or inp.get('prompt'), 100)}"
    if name.startswith("mcp__"):
        return f"Connecteur {name.split('__')[1] if '__' in name else name}"
    return short(name, 60)


def turn_texts(path):
    """Textes écrits par Claude depuis le dernier vrai message humain."""
    current = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                entry = json.loads(line)
            except Exception:
                continue
            kind = entry.get("type")
            texts, is_tool_result = texts_of(entry)
            if kind == "user" and texts and not is_tool_result and not entry.get("isMeta"):
                current = []
            elif kind == "assistant" and texts and not entry.get("isSidechain"):
                current.extend(texts)
    return "\n\n".join(t.strip() for t in current if t.strip())


def send_partial(url, token, data, key):
    path = data.get("transcript_path")
    if not path or not os.path.exists(path):
        return
    text = turn_texts(path)
    if not text:
        return
    sid = re.sub(r"[^\w-]", "", str(data.get("session_id") or "x"))
    cache = os.path.join(tempfile.gettempdir(), f"rago-hub-{sid}.partial")
    sig = str(len(text)) + ":" + text[-200:]
    try:
        with open(cache) as f:
            if f.read() == sig:
                return
    except Exception:
        pass
    try:
        with open(cache, "w") as f:
            f.write(sig)
    except Exception:
        pass
    post(url, token, "/api/hook/partial", {"key": key, "text": text[-20000:]}, timeout=6)


def on_tool(url, token, data, key):
    name = data.get("tool_name") or ""
    inp = data.get("tool_input") or {}
    try:
        send_partial(url, token, data, key)
    except Exception:
        pass
    if name in ("TodoWrite", "TaskCreate", "TaskUpdate"):
        resp = data.get("tool_response")
        if not isinstance(resp, dict):
            resp = None
        post(url, token, "/api/hook/todos", {"key": key, "tool": name, "input": inp, "response": resp}, timeout=4)
        return
    post(url, token, "/api/hook/event", {"key": key, "tool": name, "summary": describe_tool(name, inp)}, timeout=4)
    p = inp.get("file_path") or ""
    if name == "Write" and p.lower().endswith(IMG_EXT) and os.path.exists(p) and os.path.getsize(p) <= 8 * 1024 * 1024:
        with open(p, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        post(url, token, "/api/hook/file", {"key": key, "name": os.path.basename(p), "data": b64}, timeout=20)


def on_stop(url, token, data, key):
    path = data.get("transcript_path")
    if not path or not os.path.exists(path):
        return
    current, usage, model, seen = [], {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}, None, set()
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                entry = json.loads(line)
            except Exception:
                continue
            kind = entry.get("type")
            texts, is_tool_result = texts_of(entry)
            if kind == "user" and texts and not is_tool_result and not entry.get("isMeta"):
                current, seen = [], set()
                usage = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
            elif kind == "assistant":
                if texts:
                    current.extend(texts)
                msg = entry.get("message") or {}
                mid = msg.get("id")
                u = msg.get("usage") or {}
                if u and mid not in seen:  # un même message peut être écrit en plusieurs lignes
                    seen.add(mid)
                    usage["input"] += u.get("input_tokens") or 0
                    usage["output"] += u.get("output_tokens") or 0
                    usage["cacheRead"] += u.get("cache_read_input_tokens") or 0
                    usage["cacheWrite"] += u.get("cache_creation_input_tokens") or 0
                model = msg.get("model") or model
    text = "\n\n".join(t.strip() for t in current if t.strip()) or "(Le fil a terminé son tour sans message texte.)"
    post(url, token, "/api/hook/report", {
        "key": key, "text": text[-60000:], "sessionId": data.get("session_id"), "usage": usage, "model": model,
    }, timeout=10)


def main():
    url = os.environ.get("RAGO_HUB_URL", "").rstrip("/")
    token = os.environ.get("RAGO_HUB_TOKEN", "")
    if not url or not token or os.environ.get("HUB_DIRECT"):
        return
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    key = find_key(data)
    if not key:
        return
    event = data.get("hook_event_name") or ""
    if event == "PostToolUse":
        # on envoie en arrière-plan pour ne jamais ralentir Claude
        try:
            if os.fork() != 0:
                return
            os.setsid()
        except Exception:
            pass
        on_tool(url, token, data, key)
        os._exit(0)
    else:
        on_stop(url, token, data, key)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
