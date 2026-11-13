#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — M14 : vérifie que le schéma JSON (profiles/schema) et les profils
# sont d'accord : chaque profil de la base communautaire et le modèle complet
# sont valides, chaque fichier de profiles/tests/invalides/ est refusé.
# Le démon applique les mêmes règles (rago-profiled validate) ; ce test garde
# le schéma publié en accord avec lui.
#
# Usage : python3 profiles/tests/test_schema.py
# Dépendances : Python >= 3.11 (tomllib), module jsonschema.
import json
import sys
import tomllib
from pathlib import Path

try:
    import jsonschema
except ImportError:
    print("module python jsonschema absent (pip install jsonschema / paquet python-jsonschema)")
    sys.exit(2)

here = Path(__file__).resolve().parent
root = here.parent
schema = json.loads((root / "schema" / "rago-profile.schema.json").read_text())
jsonschema.Draft202012Validator.check_schema(schema)
validator = jsonschema.Draft202012Validator(schema)


def load(p: Path):
    if p.suffix == ".toml":
        return tomllib.loads(p.read_text())
    return json.loads(p.read_text())


fails = 0
total = 0


def check(cond: bool, msg: str):
    global fails, total
    total += 1
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        fails += 1


valid = sorted((root / "community").glob("*.toml")) + sorted((root / "community").glob("*.json"))
valid.append(root / "schema" / "exemple-complet.toml")
check(len(valid) >= 5, f"{len(valid)} profils valides attendus (base communautaire + modèle)")
ids = {}
appids = {}
for p in valid:
    data = load(p)
    errs = [e.message for e in validator.iter_errors(data)]
    check(not errs, f"{p.relative_to(root)} valide selon le schéma {errs if errs else ''}")
    check(data.get("id") == p.stem, f"{p.relative_to(root)} : id = nom du fichier")
    check(data.get("verified") is False, f"{p.relative_to(root)} : verified = false (aucun test matériel encore)")
    if p.parent.name == "community":
        check(data["id"] not in ids, f"{p.name} : id unique dans la base communautaire")
        ids[data["id"]] = p
        for a in data.get("match", {}).get("steam_appid", []):
            check(a not in appids, f"{p.name} : steam_appid {a} unique")
            appids[a] = p

invalid = sorted((here / "invalides").iterdir())
check(len(invalid) >= 10, f"{len(invalid)} exemples invalides")
for p in invalid:
    data = load(p)
    errs = list(validator.iter_errors(data))
    check(bool(errs), f"invalides/{p.name} refusé par le schéma")

print(f"{total - fails}/{total} PASS")
sys.exit(1 if fails else 0)
