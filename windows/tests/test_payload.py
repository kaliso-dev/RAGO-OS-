#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Rago OS (M5) : scripts Windows du micro-Windows, sans Windows.

  - syntaxe PowerShell : analyseur de pwsh s'il est installé, sinon grammaire
    tree-sitter (paquet Python tree-sitter-language-pack), sinon test sauté ;
  - Windows PowerShell 5.1 : pas de syntaxe propre à PowerShell 7, marque BOM
    (sans elle, 5.1 lit le fichier en ANSI et casse les accents, voire les
    guillemets), identifiants bcdedit entre guillemets, ConvertTo-Json -Depth ;
  - tâche planifiée, SetupComplete.cmd : ASCII, compte SYSTEM, bons chemins ;
  - liens entre fichiers (scripts appelés, paramètres, clés de micro-engine.json) ;
  - contrat avec le hook Linux host/hooks/windows-security (fichiers et champs
    de RAGO-COMM) ;
  - aucun secret ni clé de produit.
Ce qui n'est PAS vérifié ici : l'exécution réelle (DISM, Setup, démarrage),
qui demande Windows et la machine.
"""
import glob
import os
import re
import shutil
import subprocess
import unittest
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
WIN = os.path.dirname(HERE)
REPO = os.path.dirname(WIN)
PAYLOAD = os.path.join(WIN, "rago")
BIN = os.path.join(PAYLOAD, "bin")
PS_FILES = sorted(glob.glob(os.path.join(WIN, "**", "*.ps1"), recursive=True) +
                  glob.glob(os.path.join(WIN, "**", "*.psm1"), recursive=True))
HOOK = os.path.join(REPO, "host", "hooks", "windows-security")
TASK = os.path.join(PAYLOAD, "tasks", "rago-boot.xml")
SETUPCOMPLETE = os.path.join(PAYLOAD, "setup", "SetupComplete.cmd")
UNATTEND = os.path.join(WIN, "autounattend.xml")


def read(p):
    with open(p, encoding="utf-8-sig") as f:
        return f.read()


def code_only(text):
    """Le code sans commentaires ni chaînes (approximatif, suffisant pour des motifs)."""
    text = re.sub(r"<#.*?#>", "", text, flags=re.S)
    text = re.sub(r"@'.*?^'@", "''", text, flags=re.S | re.M)
    text = re.sub(r'@".*?^"@', '""', text, flags=re.S | re.M)
    out = []
    for line in text.splitlines():
        line = re.sub(r"'(?:[^']|'')*'", "''", line)
        line = re.sub(r'"(?:[^"`]|`.)*"', '""', line)
        line = re.sub(r"(^|\s)#.*$", r"\1", line)
        out.append(line)
    return "\n".join(out)


class Syntax(unittest.TestCase):
    def test_files_present(self):
        names = {os.path.relpath(p, WIN).replace(os.sep, "/") for p in PS_FILES}
        for n in ("compile_micro_engine.ps1", "rago/bin/RagoComm.psm1", "rago/bin/rago-security.ps1", "rago/bin/rago-boot.ps1",
                  "rago/bin/rago-report.ps1", "rago/bin/rago-shell.ps1", "rago/setup/firstboot.ps1"):
            self.assertIn(n, names)

    def test_parse(self):
        pwsh = shutil.which("pwsh")
        if pwsh:
            script = ("$bad = 0; foreach ($f in $args) { $t = $null; $e = $null; "
                      "[void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e); "
                      "foreach ($x in $e) { $bad++; Write-Output ('{0}:{1}: {2}' -f $f, $x.Extent.StartLineNumber, $x.Message) } }; exit $bad")
            r = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-Command", script] + PS_FILES,
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            return
        try:
            from tree_sitter_language_pack import get_parser
        except ImportError:
            self.skipTest("ni pwsh ni tree-sitter-language-pack : syntaxe PowerShell non vérifiée")
        parser = get_parser("powershell")
        for p in PS_FILES:
            with open(p, "rb") as f:
                b = f.read()
            if b.startswith(b"\xef\xbb\xbf"):
                b = b[3:]
            bad = []

            def walk(n):
                if n.type == "ERROR" or n.is_missing:
                    bad.append(n.start_point[0] + 1)
                for c in n.children:
                    walk(c)
            walk(parser.parse(b).root_node)
            self.assertEqual(bad, [], "%s : erreurs de syntaxe aux lignes %s" % (p, bad))


class WindowsPowerShell51(unittest.TestCase):
    def test_bom_when_not_ascii(self):
        for p in PS_FILES:
            with open(p, "rb") as f:
                b = f.read()
            if any(c > 127 for c in b):
                self.assertTrue(b.startswith(b"\xef\xbb\xbf"), "%s : non ASCII sans BOM (5.1 le lirait en ANSI)" % p)

    def test_no_ps7_syntax(self):
        bad = [(r"\?\?", "opérateur ??"), (r"\?\.", "opérateur ?."), (r"&&|\|\|", "chaîne && / ||"),
               (r"-Parallel\b", "ForEach-Object -Parallel"), (r"\$IsWindows\b", "$IsWindows"), (r"-AsHashtable\b", "-AsHashtable"),
               (r"utf8NoBOM", "encodage utf8NoBOM"), (r"-AsByteStream\b", "-AsByteStream"), (r"-EnumsAsStrings\b", "-EnumsAsStrings"),
               (r"-AdditionalChildPath\b", "Join-Path -AdditionalChildPath"), (r"ConvertFrom-Json\s+[^|\n]*-Depth", "ConvertFrom-Json -Depth"),
               (r"\bclean\s*\{", "bloc clean"), (r"Get-Error\b", "Get-Error"), (r"\$PSStyle\b", "$PSStyle")]
        for p in PS_FILES:
            c = code_only(read(p))
            for rx, what in bad:
                m = re.search(rx, c)
                self.assertIsNone(m, "%s : %s (PowerShell 7 seulement)" % (p, what))

    def test_strict_and_stop(self):
        for p in PS_FILES:
            t = read(p)
            self.assertIn("Set-StrictMode -Version 2.0", t, p)
            if p.endswith(".ps1") and not p.endswith("rago-shell.ps1"):
                self.assertIn("$ErrorActionPreference = 'Stop'", t, p)

    def test_bcdedit_ids_quoted(self):
        for p in PS_FILES:
            for i, line in enumerate(read(p).splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                for m in re.finditer(r"\{(current|fwbootmgr|bootmgr|default)\}", line):
                    before = line[:m.start()]
                    self.assertTrue(before.endswith("'"), "%s:%d : {%s} sans guillemets (bloc de script pour PowerShell)" % (p, i, m.group(1)))

    def test_convertto_json_depth(self):
        for p in PS_FILES:
            for i, line in enumerate(code_only(read(p)).splitlines(), 1):
                if "ConvertTo-Json" in line:
                    self.assertIn("-Depth", line, "%s:%d : ConvertTo-Json sans -Depth (5.1 coupe au 2e niveau)" % (p, i))

    def test_json_written_without_bom(self):
        # JSON lu par Linux : UTF8Encoding($false) partout où on écrit du JSON.
        for p in PS_FILES:
            t = read(p)
            for m in re.finditer(r"WriteAllText\([^\n]*", t):
                around = t[max(0, m.start() - 300):m.end() + 200]
                self.assertIn("UTF8Encoding($false)", around, p)


class TaskAndCmd(unittest.TestCase):
    def test_task_xml(self):
        with open(TASK, "rb") as f:
            raw = f.read()
        self.assertTrue(all(c < 128 for c in raw), "tâche : ASCII seulement")
        self.assertFalse(raw.lstrip().startswith(b"<?xml"), "pas de déclaration XML : passée en chaîne à l'API")
        root = ET.fromstring(raw)
        ns = {"t": "http://schemas.microsoft.com/windows/2004/02/mit/task"}
        self.assertEqual(root.tag, "{%s}Task" % ns["t"])
        self.assertEqual(root.find("t:RegistrationInfo/t:URI", ns).text, "\\Rago\\Boot")
        self.assertIsNotNone(root.find("t:Triggers/t:BootTrigger", ns))
        pr = root.find("t:Principals/t:Principal", ns)
        self.assertEqual(pr.find("t:UserId", ns).text, "S-1-5-18")
        self.assertEqual(root.find("t:Actions", ns).get("Context"), pr.get("id"))
        st = root.find("t:Settings", ns)
        self.assertEqual(st.find("t:DisallowStartIfOnBatteries", ns).text, "false")
        self.assertEqual(st.find("t:StopIfGoingOnBatteries", ns).text, "false")
        m = re.fullmatch(r"PT(\d+)M", st.find("t:ExecutionTimeLimit", ns).text)
        self.assertTrue(m and int(m.group(1)) >= 10, "limite >= 5 min d'attente du shell + 1 min de repos + marge")
        ex = root.find("t:Actions/t:Exec", ns)
        self.assertEqual(ex.find("t:Command", ns).text, r"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
        args = ex.find("t:Arguments", ns).text
        self.assertIn(r'-File "C:\Rago\bin\rago-boot.ps1"', args)
        self.assertIn("-NonInteractive", args)

    def test_setupcomplete_cmd(self):
        with open(SETUPCOMPLETE, "rb") as f:
            raw = f.read()
        self.assertTrue(all(c < 128 for c in raw), "SetupComplete.cmd : ASCII (page de code OEM de cmd.exe)")
        self.assertIn(b"\r\n", raw)
        self.assertNotIn(b"\n", raw.replace(b"\r\n", b""), "fins de ligne CRLF partout")
        t = raw.decode()
        self.assertIn(r'\Rago\setup\firstboot.ps1" -Phase setupcomplete', t)
        self.assertTrue(t.rstrip().endswith("exit /b 0"))

    def test_gitattributes_keeps_crlf(self):
        with open(os.path.join(REPO, ".gitattributes")) as f:
            self.assertRegex(f.read(), r"(?m)^\S*\*\.cmd\s+.*eol=crlf")


class CrossReferences(unittest.TestCase):
    def test_called_scripts_exist(self):
        for p in PS_FILES:
            for m in re.finditer(r"'(rago-[a-z]+\.ps1|RagoComm\.psm1|setup\\firstboot\.ps1|tasks\\rago-boot\.xml)'", read(p)):
                n = m.group(1).replace("\\", os.sep)
                ok = os.path.exists(os.path.join(BIN, n)) or os.path.exists(os.path.join(PAYLOAD, n))
                self.assertTrue(ok, "%s appelle %s, absent" % (p, n))

    def test_parameters_exist(self):
        boot = read(os.path.join(BIN, "rago-boot.ps1"))
        sec = read(os.path.join(BIN, "rago-security.ps1"))
        rep = read(os.path.join(BIN, "rago-report.ps1"))
        fb = read(os.path.join(PAYLOAD, "setup", "firstboot.ps1"))
        self.assertIn("[switch]$SettingsOnly", boot)
        for prm in ("[switch]$Apply", "[switch]$Status", "[switch]$NoReboot", "[string]$Set"):
            self.assertIn(prm, sec)
        self.assertIn("[switch]$WaitForShell", rep)
        self.assertIn("[int]$SettleSeconds", rep)
        self.assertIn("ValidateSet('specialize', 'setupcomplete')", fb)
        self.assertIn("rago-boot.ps1') -SettingsOnly", fb)
        self.assertIn("rago-security.ps1') -Apply -NoReboot", fb)
        self.assertIn("firstboot.ps1') -Phase setupcomplete", boot)
        self.assertIn("rago-report.ps1') -SettleSeconds 60 -WaitForShell", boot)
        with open(UNATTEND, encoding="utf-8") as f:
            self.assertIn(r"firstboot.ps1 -Phase specialize", f.read())

    def test_micro_engine_json_keys(self):
        comp = read(os.path.join(WIN, "compile_micro_engine.ps1"))
        block = comp[comp.index("$info = [ordered]@{"):comp.index("[System.IO.File]::WriteAllText((Join-Path $rago 'micro-engine.json')")]
        written = set(re.findall(r"\b(\w+) = ", block))
        for p in (os.path.join(PAYLOAD, "setup", "firstboot.ps1"), os.path.join(BIN, "rago-boot.ps1"), os.path.join(BIN, "rago-shell.ps1")):
            for k in re.findall(r"\$info\.(\w+)", read(p)):
                if k == "PSObject":
                    continue
                self.assertIn(k, written, "%s lit micro-engine.json : %s, que compile_micro_engine.ps1 n'écrit pas" % (p, k))
        self.assertIn("edition = $chosen.EditionId", block)

    def test_shell_command_points_to_payload(self):
        comp = read(os.path.join(WIN, "compile_micro_engine.ps1"))
        m = re.search(r"\[string\]\$ShellCommand = '([^']+)'", comp)
        self.assertIn(r'-File "C:\Rago\bin\rago-shell.ps1"', m.group(1))
        self.assertTrue(os.path.exists(os.path.join(BIN, "rago-shell.ps1")))

    def test_payload_has_no_tests_or_cache(self):
        for root, dirs, files in os.walk(PAYLOAD):
            self.assertNotIn("__pycache__", dirs)
            for f in files:
                self.assertRegex(f, r"\.(ps1|psm1|cmd|xml)$", os.path.join(root, f))


class HookContract(unittest.TestCase):
    """Fichiers et champs de RAGO-COMM : mêmes noms des deux côtés."""

    def test_profile_request(self):
        with open(HOOK, encoding="utf-8") as f:
            hook = f.read()
        sec = read(os.path.join(BIN, "rago-security.ps1"))
        self.assertIn('"kind": "rago-windows-security"', hook)
        self.assertIn("$req.kind -eq 'rago-windows-security'", sec)
        self.assertIn('"schema": 1', hook)
        self.assertIn("$req.schema -eq 1", sec)
        for field in ("security", "profile_id"):
            self.assertIn('"%s"' % field, hook)
            self.assertIn("'%s'" % field, sec)
        self.assertIn('comm.path("security", "profile.json")', hook)
        self.assertIn(r"'security\profile.json'", sec)
        self.assertIn('comm.path("security", "status.json")', hook)
        self.assertIn(r"'security\status.json'", sec)
        self.assertIn('comm.path("reports")', hook)
        self.assertIn(r"'reports\m5-engine.json'", read(os.path.join(BIN, "rago-report.ps1")))
        rc = read(os.path.join(BIN, "RagoComm.psm1"))
        self.assertIn("$script:CommLabel   = 'RAGO-COMM'", rc)
        with open(os.path.join(REPO, "host", "rago-comm.conf"), encoding="utf-8") as f:
            self.assertIn("/dev/disk/by-label/RAGO-COMM", f.read())

    def test_values(self):
        rc = read(os.path.join(BIN, "RagoComm.psm1"))
        self.assertIn("$Value -eq 'compat_max' -or $Value -eq 'perf'", rc)
        with open(HOOK, encoding="utf-8") as f:
            hook = f.read()
        self.assertRegex(hook, r"compat_max.*perf|perf.*compat_max")


class NoSecrets(unittest.TestCase):
    def test_no_product_key_or_password(self):
        key = re.compile(r"\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b")
        for p in glob.glob(os.path.join(WIN, "**", "*"), recursive=True):
            if os.path.isdir(p) or p.endswith(".pyc"):
                continue
            with open(p, encoding="utf-8-sig", errors="replace") as f:
                t = f.read()
            self.assertIsNone(key.search(t), "%s : ressemble à une clé de produit" % p)
            self.assertNotRegex(t, r"(?i)DefaultPassword\s*=\s*'[^']+'", p)


if __name__ == "__main__":
    unittest.main()
