#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Rago OS (M7) : agent Windows de la bibliothèque partagée, sans Windows.

Validation STATIQUE seulement (l'agent n'a jamais été exécuté : Windows,
conteneur Linux). La syntaxe PowerShell, la marque BOM, Set-StrictMode et
l'absence de syntaxe PowerShell 7 sont vérifiées pour tous les scripts par
test_payload.py. Ici :
  - contrat avec Linux (host/lib/rago_library.py) : types de fichiers, états,
    expressions des identifiants, chemins de RAGO-COMM\\library, arborescence
    de RAGO-LIB, champs lus par Linux ;
  - ordre de sûreté : « running » écrit AVANT la mise en ligne de RAGO-LIB,
    « off » écrit APRÈS sa mise hors ligne, jamais ailleurs ;
  - rien d'interdit : formatage, réparation forcée, sécurité de Windows,
    anti-triche, Microsoft Store ;
  - launchers.json : adresses https des éditeurs, signataires, produits Riot ;
  - branchement : rago-boot.ps1, rago-shell.ps1, compile_micro_engine.ps1.
"""
import importlib.util
import json
import os
import re
import unittest
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
WIN = os.path.dirname(HERE)
REPO = os.path.dirname(WIN)
AGENT = os.path.join(WIN, "rago-agent")
BIN = os.path.join(WIN, "rago", "bin")
HELPER = os.path.join(REPO, "host", "lib", "rago_library.py")

spec = importlib.util.spec_from_file_location("rago_library", HELPER)
rl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rl)


def read(p):
    with open(p, encoding="utf-8-sig") as f:
        return f.read()


def code_only(text):
    """Sans commentaires « # » ni blocs <# #> (approximatif, suffisant ici)."""
    text = re.sub(r"<#.*?#>", "", text, flags=re.S)
    out = []
    for line in text.splitlines():
        s = line.lstrip()
        if s.startswith("#"):
            continue
        out.append(line)
    return "\n".join(out)


def function_body(text, name):
    i = text.index("function %s {" % name)
    depth = 0
    for j in range(text.index("{", i), len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    raise AssertionError("fonction %s non fermée" % name)


AGENT_PS = read(os.path.join(AGENT, "rago-agent.ps1"))
MOD = read(os.path.join(AGENT, "RagoAgent.psm1"))
LAUNCH = read(os.path.join(AGENT, "RagoLaunchers.psm1"))
ALL_PS = {n: read(os.path.join(AGENT, n)) for n in ("rago-agent.ps1", "RagoAgent.psm1", "RagoLaunchers.psm1")}
with open(os.path.join(AGENT, "launchers.json"), encoding="utf-8") as f:
    LAUNCHERS = json.load(f)
with open(os.path.join(AGENT, "agent.json"), encoding="utf-8") as f:
    CONFIG = json.load(f)


class Files(unittest.TestCase):
    def test_present(self):
        for n in ("rago-agent.ps1", "RagoAgent.psm1", "RagoLaunchers.psm1", "agent.json", "launchers.json", "README.md"):
            self.assertTrue(os.path.isfile(os.path.join(AGENT, n)), n)

    def test_only_payload_files(self):
        # Tout le dossier est copié dans C:\Rago\agent : pas de test ni de cache dedans.
        for n in os.listdir(AGENT):
            self.assertRegex(n, r"\.(ps1|psm1|json|md)$")

    def test_marked_never_run(self):
        for n, t in ALL_PS.items():
            self.assertIn("Jamais exécuté", t, n)

    def test_json_files_ascii_no_bom(self):
        for n in ("agent.json", "launchers.json"):
            with open(os.path.join(AGENT, n), "rb") as f:
                b = f.read()
            self.assertFalse(b.startswith(b"\xef\xbb\xbf"), n)


class Contract(unittest.TestCase):
    """Mêmes noms, mêmes règles des deux côtés de RAGO-COMM."""

    def ps_string(self, name):
        m = re.search(r"\$script:%s = '([^']*)'" % name, MOD)
        self.assertIsNotNone(m, name)
        return m.group(1)

    def test_id_patterns_identical(self):
        self.assertEqual(self.ps_string("KeyRx"), rl.KEY_RE.pattern)
        self.assertEqual(self.ps_string("ReqRx"), rl.REQ_ID_RE.pattern)
        # Comparaisons sensibles à la casse côté Windows (-match ne l'est pas).
        for t in ALL_PS.values():
            self.assertNotRegex(code_only(t), r"-match \$script:(KeyRx|ReqRx)")

    def test_requests_from_linux_accepted_by_windows(self):
        req_rx = re.compile(self.ps_string("ReqRx"))
        key_rx = re.compile(self.ps_string("KeyRx"))
        for action in ("install", "launch"):
            for launcher, lid in (("steam", "730"), ("epic", "Fortnite"), ("epic", "fn:4fe75bbc5a674f4f9b356b5c90567da5:Fortnite"),
                                  ("riot", "valorant"), ("riot", "league_of_legends")):
                r = rl.build_request(action, launcher, lid)
                self.assertTrue(req_rx.fullmatch(r["id"]), r["id"])
                self.assertTrue(key_rx.fullmatch(r["game_key"]), r["game_key"])
                for field in ("kind", "id", "game_key", "launcher_id", "action", "launcher"):
                    self.assertIn(field, r)
        # Champs exigés par Get-RagoRequests : tous écrits par build_request.
        body = function_body(MOD, "Get-RagoRequests")
        for field in re.findall(r"Test-RagoProp \$r '(\w+)'", body):
            self.assertIn(field, r)
        self.assertIn("'rago-library-request'", body)

    def test_result_states(self):
        m = re.search(r"\[ValidateSet\(([^)]*)\)\]\[string\]\$State,\s*\[string\]\$Message", MOD)
        self.assertIsNotNone(m)
        self.assertEqual(tuple(re.findall(r"'(\w+)'", m.group(1))), rl.RESULT_STATES)
        body = function_body(MOD, "Get-RagoOpenResults")
        opened = set(re.findall(r"'(\w+)'", re.search(r"@\(('\w+'(, )?)+\) -contains", body).group(0)))
        self.assertEqual(opened, set(rl.RESULT_STATES) - set(rl.FINISHED))
        # Linux ne passe en résultat effaçable que ce qui est fini.
        self.assertIn("cancelled", rl.FINISHED)

    def test_windows_states(self):
        m = re.search(r"\[ValidateSet\(([^)]*)\)\]\[string\]\$State,\s*\[Parameter\(Mandatory = \$true\)\]\$Lib", MOD)
        self.assertIsNotNone(m)
        self.assertEqual(tuple(re.findall(r"'(\w+)'", m.group(1))), rl.STATES)

    def test_kinds(self):
        helper = read(HELPER)
        for kind in ("rago-library-windows-state", "rago-library-partition", "rago-library-request",
                     "rago-library-game", "rago-library"):
            self.assertIn('"%s"' % kind, helper, kind)
            self.assertIn("'%s'" % kind, MOD, kind)
        self.assertIn("'rago-library-result'", MOD)
        self.assertIn('"rago-library-result"', helper)

    def test_comm_paths(self):
        helper = read(HELPER)
        for py, ps in (('"library", "windows-state.json"', "'windows-state.json'"),
                       ('"library", "partition.json"', "'partition.json'"),
                       ('"library", "requests"', "'requests'"),
                       ('"library", "results"', "'results\\{0}.json'")):
            self.assertIn(py, helper, py)
            self.assertIn(ps, MOD + AGENT_PS, ps)
        self.assertIn("Join-Path $CommRoot 'library'", MOD)

    def test_library_tree_identical(self):
        helper = read(HELPER)
        py = function_body_py(helper, "cmd_init")
        py_dirs = set()
        for m in re.finditer(r'os\.path\.join\(((?:"[^"]+",?\s*)+)\)|"(\.rago|Games)"', py):
            if m.group(1):
                py_dirs.add("/".join(re.findall(r'"([^"]+)"', m.group(1))))
            else:
                py_dirs.add(m.group(2))
        py_dirs.discard(".rago/library.json")
        body = function_body(MOD, "Initialize-RagoLibTree")
        ps_dirs = set(d.replace("\\", "/") for d in re.findall(r"'([^']+)'", body[body.index("@("):body.index(")", body.index("@("))]))
        self.assertEqual(ps_dirs, py_dirs)
        for launcher in ("steam", "epic", "riot"):
            self.assertIn(LAUNCHERS[launcher]["library_dir"].replace("\\", "/"), ps_dirs)

    def test_lib_fields_read_by_linux(self):
        # decide_from lit lib.found et lib.offline : chaque objet « lib » écrit par Windows les a.
        for name in ("Mount-RagoLib", "Dismount-RagoLib"):
            body = function_body(MOD, name)
            first = body[body.index("$lib = [ordered]@{"):]
            first = first[:first.index("\n")]
            for field in ("found", "offline", "partuuid", "online", "error"):
                self.assertIn(field + " = ", first, (name, field))
        boot = function_body(AGENT_PS, "Invoke-RagoAgentBoot")
        shut = function_body(AGENT_PS, "Invoke-RagoAgentShutdown")
        for body in (boot, shut):
            for line in body.splitlines():
                if re.search(r"= \[ordered\]@\{ found = \$(true|false);", line):
                    self.assertIn("offline = ", line)
        # « offline » n'est vrai que si Windows le confirme (IOCTL_VOLUME_IS_OFFLINE).
        for name in ("Mount-RagoLib", "Dismount-RagoLib"):
            body = function_body(MOD, name)
            for m in re.finditer(r"\$lib\.offline = ([^\n]*)", body):
                self.assertIn("Test-RagoVolumeOffline", m.group(1), (name, m.group(0)))
        # Jamais de test de lecture d'un chemin \\?\ par .NET : Windows PowerShell 5.1
        # (cible ancienne de .NET Framework) peut le refuser et faire croire le volume hors ligne.
        for t in ALL_PS.values():
            self.assertNotRegex(code_only(t), r"\[System\.IO\.(Directory|File)\]::Exists\(\$vol")
        test = function_body(MOD, "Test-RagoVolumeOffline")
        self.assertIn("return $false", test)
        self.assertIn("0x00560010", MOD)  # CTL_CODE('V', 4, METHOD_BUFFERED, FILE_ANY_ACCESS)
        self.assertEqual((0x56 << 16) | (0 << 14) | (4 << 2) | 0, 0x00560010)

    def test_game_record_fields(self):
        body = function_body(AGENT_PS, "Complete-RagoGame")
        for field in ("key", "launcher", "launcher_id", "name", "installed", "install_dir", "size_bytes",
                      "installed_at", "installed_by_windows", "client_ids", "client_cache", "finalized", "last_launch_at"):
            self.assertRegex(body, r"\b%s = " % field)
        self.assertIn("ConvertTo-RagoLibRelative", body)
        # Relatif, séparateurs « / » (lu par read_games côté Linux).
        conv = function_body(MOD, "ConvertTo-RagoLibRelative")
        self.assertIn(".Replace('\\', '/')", conv)


def function_body_py(text, name):
    i = text.index("def %s(" % name)
    j = text.find("\ndef ", i + 1)
    return text[i:j if j > 0 else len(text)]


class SafetyOrder(unittest.TestCase):
    def test_running_before_online(self):
        boot = code_only(function_body(AGENT_PS, "Invoke-RagoAgentBoot"))
        first_state = boot.index("Write-RagoWindowsState -CommRoot $comm -State running")
        self.assertLess(first_state, boot.index("Mount-RagoLib"))
        # Sans RAGO-COMM : on s'arrête AVANT de toucher RAGO-LIB.
        self.assertLess(boot.index("if (-not $comm) { throw"), boot.index("Mount-RagoLib"))
        self.assertNotIn("-State off", boot)

    def test_off_after_offline(self):
        shut = code_only(function_body(AGENT_PS, "Invoke-RagoAgentShutdownLocked"))
        self.assertLess(shut.index("Dismount-RagoLib"), shut.index("-State off"))
        # Sans le verrou, « hors ligne » n'est jamais affirmé.
        self.assertLess(shut.index("if (-not $Locked)"), shut.index("-State off"))
        self.assertIn("$lib.offline = $false", shut[shut.index("if (-not $Locked)"):])
        # « off » écrit seulement par l'arrêt.
        for n, t in ALL_PS.items():
            if n == "rago-agent.ps1":
                t = t.replace(function_body(AGENT_PS, "Invoke-RagoAgentShutdownLocked"), "")
            self.assertFalse("-State off" in code_only(t), n)

    def test_boot_and_shutdown_never_cross(self):
        # Relecture : le joueur peut éteindre pendant que \Rago\Boot met RAGO-LIB en ligne.
        boot = code_only(function_body(AGENT_PS, "Invoke-RagoAgentBoot"))
        lock = boot.index("Enter-RagoLibraryLock")
        self.assertLess(lock, boot.index("Test-RagoShutdownStarted"))
        self.assertLess(boot.index("Test-RagoShutdownStarted"), boot.index("Write-RagoWindowsState"))
        self.assertLess(boot.index("Write-RagoWindowsState"), boot.index("Mount-RagoLib"))
        self.assertIn("Exit-RagoLibraryLock $lock", boot[boot.index("} finally {"):])
        shut = code_only(function_body(AGENT_PS, "Invoke-RagoAgentShutdown"))
        self.assertLess(shut.index("$shutdownMarkPath"), shut.index("Enter-RagoLibraryLock"))
        self.assertIn("Invoke-RagoAgentShutdownLocked -Locked ($null -ne $lock)", shut)
        self.assertIn("Exit-RagoLibraryLock $lock", shut)
        self.assertIn("'Global\\RagoLibraryVolume'", AGENT_PS)

    def test_dirty_volume_repaired_before_any_write(self):
        # Relecture : hors ligne au démarrage, RAGO-LIB n'est jamais vue par autochk.
        boot = code_only(function_body(AGENT_PS, "Invoke-RagoAgentBoot"))
        rep = boot.index("Repair-RagoLibIfDirty")
        self.assertLess(boot.index("Mount-RagoLib"), rep)
        for w in ("Grant-RagoLibUsers", "$info.lib_root = $root"):
            self.assertLess(rep, boot.index(w), w)
        fail = boot[rep:boot.index("$info.lib_root = $root")]
        self.assertIn("$lib.online = $false", fail)
        # Pas réparée : lib_root reste vide, donc remise hors ligne dans « finally ».
        fin = boot[boot.index("} finally {"):]
        self.assertIn("if ($null -ne $lock -and -not $info.lib_root)", fin)
        self.assertIn("Close-RagoLibIfOnline", fin)
        self.assertLess(fin.index("Close-RagoLibIfOnline"), fin.index("Exit-RagoLibraryLock"))
        self.assertIn("Dismount-RagoLib", function_body(AGENT_PS, "Close-RagoLibIfOnline"))
        body = code_only(function_body(MOD, "Repair-RagoLibIfDirty"))
        self.assertLess(body.index("if ($res.dirty -eq $false)"), body.index("Repair-Volume"))
        self.assertIn("-OfflineScanAndFix", body)
        self.assertIn("$res.ok = ($after -eq $false)", body)
        self.assertIn("0x00090078", MOD)
        # La réparation n'est faite que là.
        for n, t in ALL_PS.items():
            c = code_only(t)
            if n == "RagoAgent.psm1":
                c = c.replace(code_only(function_body(MOD, "Repair-RagoLibIfDirty")), "")
            self.assertNotIn("Repair-Volume", c, n)

    def test_state_flushed_before_touching_lib(self):
        body = function_body(MOD, "Write-RagoWindowsState")
        self.assertLess(body.index("Write-RagoJson"), body.index("Sync-RagoComm"))
        dis = function_body(MOD, "Dismount-RagoLib")
        self.assertLess(dis.index("Sync-RagoVolume -DriveLetter"), dis.index("'/P'"))

    def test_session_never_touches_volume(self):
        sess = function_body(AGENT_PS, "Invoke-RagoAgentSession") + function_body(AGENT_PS, "Step-RagoRequest")
        for bad in ("Mount-RagoLib", "Dismount-RagoLib", "mountvol", "Write-RagoWindowsState"):
            self.assertNotIn(bad, sess)

    def test_forbidden(self):
        bad = [r"Format-Volume", r"Clear-Disk", r"Remove-Partition", r"Initialize-Disk", r"Set-Partition",
               r"New-Partition", r"chkdsk", r"fsutil", r"\bbcdedit", r"testsigning", r"nointegritychecks",
               r"Set-MpPreference", r"DisableAntiSpyware", r"Stop-Service", r"Set-Service", r"\bsc\.exe",
               r"\bvgk\b", r"\bvgc\b", r"HypervisorEnforcedCodeIntegrity", r"DeviceGuard", r"ms-windows-store",
               r"WindowsApps", r"Get-AppxPackage", r"xboxapp", r"GamePass", r"'/N'", r"'/R'", r"IsHidden",
               r"Set-ExecutionPolicy", r"Invoke-Expression", r"\biex\b", r"DownloadString"]
        for n, t in ALL_PS.items():
            c = code_only(t)
            for b in bad:
                self.assertNotRegex(c, b, "%s : %s" % (n, b))

    def test_installers_verified_before_run(self):
        body = function_body(LAUNCH, "Get-RagoOfficialInstaller")
        self.assertIn("'^https://'", body)
        self.assertIn("Get-AuthenticodeSignature", body)
        self.assertIn("$sig.Status -ne 'Valid'", body)
        self.assertLess(body.index("Get-AuthenticodeSignature"), body.index("return"))
        for name in ("Install-RagoSteamClient", "Install-RagoEpicClient", "Install-RagoRiotClient"):
            self.assertIn("Get-RagoOfficialInstaller", function_body(LAUNCH, name), name)
        # Aucun autre téléchargement.
        for n, t in ALL_PS.items():
            c = code_only(t)
            if n == "RagoLaunchers.psm1":
                c = c.replace(code_only(body), "")
            self.assertNotIn("Invoke-WebRequest", c, n)
            self.assertNotIn("WebClient", c, n)

    def test_gpo_shutdown_script(self):
        self.assertIn("'{42B5FAAE-6536-11D2-AE5A-0000F87571E3}'", MOD)
        self.assertIn("'{40B6664F-4972-11D1-A7CA-0000F87571E3}'", MOD)
        body = function_body(MOD, "Set-RagoShutdownScript")
        self.assertIn("[Shutdown]", body)
        self.assertIn("-Shutdown", body)
        self.assertIn("-Encoding Unicode", body)
        self.assertIn("-Encoding Ascii", body)
        self.assertIn("Group Policy\\State\\Machine\\Scripts\\Shutdown", body)


class Review(unittest.TestCase):
    """Défauts trouvés par la relecture indépendante (14/11), pour qu'ils ne reviennent pas."""

    def test_volume_regexes_accept_real_path(self):
        # Le motif de Test-RagoVolumeOffline n'acceptait qu'UNE barre au début :
        # Windows n'aurait jamais confirmé RAGO-LIB hors ligne.
        guid_rx = re.search(r"\$a -match '([^']+)'\) \{ return \[string\]\$a", MOD).group(1)
        off_rx = re.search(r"\$VolumePath -cmatch '([^']+)'", MOD).group(1)
        sample = "\\\\?\\Volume{0a1b2c3d-1111-2222-3333-444455556666}\\"
        self.assertTrue(re.search(guid_rx, sample))
        m = re.search(off_rx, sample)
        self.assertIsNotNone(m, "Test-RagoVolumeOffline refuse \\\\?\\Volume{...}\\")
        self.assertEqual(m.group(1), "Volume{0a1b2c3d-1111-2222-3333-444455556666}")
        for bad in ("\\?\\Volume{0a1b2c3d-1111-2222-3333-444455556666}\\", "C:\\", "\\\\.\\Volume{x}\\"):
            self.assertIsNone(re.search(off_rx, bad), bad)

    def test_shutdown_found_false_only_when_sure(self):
        body = code_only(function_body(AGENT_PS, "Invoke-RagoAgentShutdownLocked"))
        self.assertIn("[ordered]@{ found = $null;", body)
        self.assertNotIn("@{ found = $false", body)
        self.assertEqual(body.count("$lib.found = $false"), 1)
        i = body.index("$lib.found = $false")
        self.assertIn("Read-RagoBootInfo", body[:i])
        self.assertIn("$boot.lib_root", body[:i])
        self.assertLess(body.index("$lib.found = $true"), body.index("Dismount-RagoLib"))

    def test_resumed_requests_reopen_client_once(self):
        body = code_only(function_body(AGENT_PS, "Step-RagoRequest"))
        self.assertNotIn("$null -eq $Prev", body)
        self.assertIn("$kick = Test-RagoKick $Req", body)
        # Chaque « … installe le jeu » (suivi d'une installation) rouvre le client une fois.
        for msg in ("'Steam installe le jeu sur RAGO-LIB'", "'le lanceur Epic installe le jeu sur RAGO-LIB'",
                    "'le Riot Client installe le jeu sur RAGO-LIB'"):
            i = body.index(msg)
            before = body[max(0, body.rfind("{", 0, body.rfind("if (", 0, i)) - 400):i]
            self.assertIn("if ($kick", before, msg)
            self.assertIn("Start-Process", before, msg)

    def test_client_install_tried_once_per_session(self):
        body = code_only(function_body(AGENT_PS, "Step-RagoRequest"))
        for call, name in (("Install-RagoSteamClient", "steam"), ("Install-RagoEpicClient", "epic")):
            for m in re.finditer(re.escape(call), body):
                self.assertIn("Test-RagoClientTry '%s'" % name, body[max(0, m.start() - 400):m.start()], call)

    def test_timeout_counts_session_time(self):
        body = code_only(function_body(AGENT_PS, "Invoke-RagoAgentSession"))
        self.assertNotIn("started_at", body)
        self.assertIn("$script:SeenAt", body)
        self.assertIn("dans une meme session", CONFIG["doc"])

    def test_open_result_errors_end_in_failed(self):
        body = code_only(function_body(AGENT_PS, "Invoke-RagoAgentSession"))
        self.assertIn("$script:Strikes", body)
        self.assertRegex(body, r"if \(\$n -ge 3\) \{ Write-RagoJob \$comm \$res 'failed'")

    def test_riot_needs_all_main_files(self):
        body = code_only(function_body(LAUNCH, "Get-RagoRiotProduct"))
        self.assertLess(body.index("$exeOk = $true"), body.index("foreach ($rel in @($p.main_files))"))
        self.assertIn("{ $exeOk = $false }", body)

    def test_system_never_reads_library_data(self):
        # Relecture : RAGO-LIB est modifiable par les Utilisateurs ; SYSTEM n'y lit
        # ni n'y écrit rien d'autre que les droits de la racine (sinon un programme
        # du joueur pourrait faire écrire SYSTEM n'importe où).
        system = code_only(function_body(AGENT_PS, "Invoke-RagoAgentBoot")) + \
            code_only(function_body(AGENT_PS, "Invoke-RagoAgentShutdownLocked"))
        for bad in ("Invoke-RagoFinalize", "Initialize-RagoLibTree", "Read-RagoGameRecord", "Write-RagoGameRecord",
                    "Restore-RagoClientFile", ".rago"):
            self.assertNotIn(bad, system, bad)
        sess = code_only(function_body(AGENT_PS, "Invoke-RagoAgentSession"))
        self.assertLess(sess.index("Initialize-RagoLibTree"), sess.index("while ($true)"))
        self.assertLess(sess.index("Invoke-RagoFinalize"), sess.index("while ($true)"))
        fin = code_only(function_body(AGENT_PS, "Invoke-RagoFinalize"))
        self.assertNotIn("Install-RagoVcFromRedist", fin)
        self.assertIn("if (-not $vcOk)", fin)
        self.assertLess(fin.index("if (-not $vcOk)"), fin.index("$rec.finalized ="))
        self.assertIn("'^[A-Za-z0-9._-]{1,64}$'", fin)

    def test_signer_is_exact_name(self):
        # Relecture : plus de recherche de « Valve » n'importe où dans le DN.
        body = code_only(function_body(LAUNCH, "Get-RagoOfficialInstaller"))
        self.assertIn("X509NameType]::SimpleName", body)
        self.assertIn("$cn -cmatch $SignerRx", body)
        self.assertNotIn("$subject -match", body)
        self.assertIn("-PassThru", body)
        self.assertIn("ResponseUri", body)
        good = {"steam": ["Valve Corp.", "Valve Corporation"], "epic": ["Epic Games Inc.", "Epic Games, Inc."],
                "riot": ["Riot Games, Inc."]}
        bad = ["Valvetronic Ltd", "Valve", "Epic Games Fan Club", "xRiot Games, Inc.", "Riot Games Fan Studio LLC",
               "CN=Valve Corp., O=Valve Corp."]
        for name, rx in ((k, LAUNCHERS[k]["signer_rx"]) for k in ("steam", "epic", "riot")):
            self.assertTrue(rx.startswith("^") and rx.endswith("$"), name)
            for g in good[name]:
                self.assertTrue(re.search(rx, g), (name, g))
            for b in bad:
                self.assertIsNone(re.search(rx, b), (name, b))

    def test_native_stderr_never_throws(self):
        # Windows PowerShell 5.1 : « 2>&1 » + « Stop » fait d'une ligne d'erreur une exception.
        for name, text in ALL_PS.items():
            code = code_only(text)
            for m in re.finditer(r"2>&1", code):
                fn = code.rfind("function ", 0, m.start())
                self.assertTrue(code.startswith("function Invoke-RagoNative", fn), f"{name} : 2>&1 hors de Invoke-RagoNative")
        self.assertIn("$ErrorActionPreference = 'Continue'", function_body(MOD, "Invoke-RagoNative"))


class Launchers(unittest.TestCase):
    HOSTS = {"steam": ("steamstatic.com", "steampowered.com"), "epic": ("epicgames.com",), "riot": ("riotcdn.net",)}

    def urls(self):
        for name in ("steam", "epic"):
            yield name, LAUNCHERS[name]["installer_url"]
        for pid, p in LAUNCHERS["riot"]["products"].items():
            yield "riot", p["installer_url"]

    def test_official_https(self):
        for name, url in self.urls():
            u = urlparse(url)
            self.assertEqual(u.scheme, "https", url)
            self.assertTrue(any(u.hostname == h or u.hostname.endswith("." + h) for h in self.HOSTS[name]), url)

    def test_signers_and_sources(self):
        for name in ("steam", "epic", "riot"):
            l = LAUNCHERS[name]
            self.assertTrue(l["signer_rx"])
            re.compile(l["signer_rx"])
            self.assertTrue(any(k.endswith("source") for k in l), name)
            self.assertTrue(l["library_dir"].startswith("Games\\"), name)

    def test_uri_templates(self):
        self.assertIn("{id}", LAUNCHERS["steam"]["install_uri"])
        self.assertTrue(any("{id}" in a for a in LAUNCHERS["steam"]["launch_args"]))
        for k in ("install_uri_full", "launch_uri"):
            for part in ("{ns}", "{cat}", "{app}"):
                self.assertIn(part, LAUNCHERS["epic"][k])
        self.assertTrue(any("{id}" in a for a in LAUNCHERS["riot"]["launch_args"]))

    def test_riot_products_match_linux(self):
        prods = LAUNCHERS["riot"]["products"]
        self.assertEqual(set(prods), set(rl.RIOT_KNOWN))
        for pid, p in prods.items():
            self.assertTrue(rl.ID_RULES["riot"].fullmatch(pid))
            self.assertTrue(p["main_files"])
            self.assertIn("reboot_after_install", p)

    def test_no_store(self):
        self.assertEqual(set(LAUNCHERS) - {"schema", "kind", "doc"}, {"steam", "epic", "riot"})
        self.assertEqual(set(rl.LAUNCHERS), {"steam", "epic", "riot"})

    def test_agent_config(self):
        self.assertEqual(CONFIG["kind"], "rago-agent-config")
        self.assertRegex(CONFIG["lib_letter"], r"^[D-Z]$")
        self.assertNotIn(CONFIG["lib_letter"], ("C", "R"))
        self.assertTrue(1 <= CONFIG["poll_seconds"] <= 600)
        self.assertTrue(1 <= CONFIG["job_timeout_hours"] <= 240)


class Wiring(unittest.TestCase):
    def test_agent_parameters(self):
        for prm in ("[switch]$Boot", "[switch]$Shutdown", "[switch]$Session", "[switch]$Status",
                    "[switch]$RegisterShutdown", "[string]$Abandon", "[int]$WaitSeconds"):
            self.assertIn(prm, AGENT_PS)

    def test_boot_task(self):
        boot = read(os.path.join(BIN, "rago-boot.ps1"))
        c = code_only(boot)
        self.assertIn("Join-Path (Get-RagoRootDir) 'agent\\rago-agent.ps1'", c)
        # Script d'arrêt posé aussi pendant l'installation (-SettingsOnly).
        self.assertLess(c.index("& $agent -RegisterShutdown"), c.index("if ($SettingsOnly) { return }"))
        # RAGO-LIB en ligne seulement si ce démarrage ne redémarre pas pour la sécurité.
        self.assertLess(c.index("$st.reboot -eq 'started'"), c.index("& $agent -Boot"))
        self.assertLess(c.index("& $sec -Apply"), c.index("& $agent -Boot"))

    def test_shell(self):
        shell = code_only(read(os.path.join(BIN, "rago-shell.ps1")))
        self.assertIn("'-Session'", shell)
        self.assertIn("-Abandon", shell)
        self.assertIn("-Status", shell)
        self.assertIn("'B' { Invoke-RagoLibraryMenu", shell)
        # Session lancée après l'attente de l'état de sécurité.
        self.assertLess(shell.index("Show-RagoStatus $status"), shell.index("try { Start-RagoLibrarySession }"))

    def test_build_copies_agent(self):
        comp = read(os.path.join(WIN, "compile_micro_engine.ps1"))
        self.assertIn("[string]$AgentPath = (Join-Path $PSScriptRoot 'rago-agent')", comp)
        self.assertIn("$agentDst = Join-Path $rago 'agent'", comp)
        self.assertIn("(Join-Path $AgentPath 'rago-agent.ps1')", comp)
        # C:\Rago reste en lecture seule pour les Utilisateurs (après la copie de l'agent).
        self.assertLess(comp.index("$agentDst = Join-Path $rago 'agent'"), comp.index("'*S-1-5-32-545:(OI)(CI)RX'"))

    def test_agent_paths_from_payload(self):
        # rago-agent.ps1 importe RagoComm.psm1 depuis C:\Rago\bin.
        self.assertIn("Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\\RagoComm.psm1'", AGENT_PS)
        self.assertTrue(os.path.isfile(os.path.join(BIN, "RagoComm.psm1")))
        comm = read(os.path.join(BIN, "RagoComm.psm1"))
        used = set(re.findall(r"\b(Get-RagoDataDir|Get-RagoRootDir|Set-RagoLogName|Write-RagoLog|Get-RagoUtcNow|Get-RagoBootId|"
                              r"Write-RagoJson|Read-RagoJson|Get-RagoCommRoot)\b", "\n".join(ALL_PS.values())))
        for fn in used:
            self.assertIn("function %s" % fn, comm)
            self.assertRegex(comm, r"Export-ModuleMember[^\n]*(\n\s+[^\n]*)*%s" % fn)

    def test_exported_functions_exist(self):
        for n in ("RagoAgent.psm1", "RagoLaunchers.psm1"):
            t = ALL_PS[n]
            exp = t[t.index("Export-ModuleMember"):]
            names = re.findall(r"\b[A-Z][A-Za-z]+-Rago\w+", exp)
            defined = set(re.findall(r"^function ([\w-]+)", t, re.M))
            self.assertEqual(set(names), defined, n)

    def test_called_functions_defined(self):
        defined = set()
        for t in ALL_PS.values():
            defined |= set(re.findall(r"^function ([\w-]+)", t, re.M))
        comm = read(os.path.join(BIN, "RagoComm.psm1"))
        defined |= set(re.findall(r"^function ([\w-]+)", comm, re.M))
        for n, t in ALL_PS.items():
            for fn in set(re.findall(r"\b((?:Get|Set|Test|Write|Read|Invoke|Install|Find|Mount|Dismount|Grant|Initialize|"
                                     r"Sync|ConvertTo|Expand|Restore|Complete|Step|Show|Remove)-Rago\w+)", code_only(t))):
                self.assertIn(fn, defined, "%s appelle %s" % (n, fn))


if __name__ == "__main__":
    unittest.main(verbosity=1)
