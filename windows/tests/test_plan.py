#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Rago OS (M5) : le plan d'ablation (windows/micro_engine_plan.json) est sûr.

Vérifié sans Windows :
  - structure, types de registre, valeurs ;
  - aucun service protégé (sécurité, réseau, anti-triche) dans la liste à couper ;
  - la base de sécurité (VBS + HVCI + liste de blocage des pilotes) est là, sans
    verrou UEFI, et identique à celle de rago-security.ps1 ;
  - rien ne touche à Defender, aux services par le registre, ni à la protection
    de pile matérielle du noyau ;
  - SIMULATION de la sélection faite par compile_micro_engine.ps1 (même règle :
    jokers -like, casse ignorée, « keep » l'emporte) sur des inventaires réalistes
    de Windows 11 24H2 / 25H2 : ce qui doit rester reste.

Les inventaires ci-dessous sont écrits à la main (noms tels que DISM les
affiche) : ce n'est PAS une image réelle. La vraie liste est dans le rapport
de compile_micro_engine.ps1 -PlanOnly.
"""
import fnmatch
import json
import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
WIN = os.path.dirname(HERE)
PLAN = os.path.join(WIN, "micro_engine_plan.json")
SECURITY_PS1 = os.path.join(WIN, "rago", "bin", "rago-security.ps1")

with open(PLAN, encoding="utf-8") as f:
    plan = json.load(f)


def like(name, patterns):
    """Opérateur -like de PowerShell (jokers * ? [ ], casse ignorée)."""
    return any(fnmatch.fnmatchcase(name.lower(), p.lower()) for p in patterns)


def select_appx(names):
    rm = [n for n in names if not like(n, plan["appx"]["keep"]) and like(n, plan["appx"]["remove"])]
    return rm, [n for n in names if n not in rm]


def select_caps(names, lang):
    c = plan["capabilities"]
    removed = []
    for n in names:
        parts = n.split("~")
        cap_lang = parts[3] if len(parts) >= 4 else ""
        if like(n, c["keep"]):
            continue
        if like(n, c["remove"]):
            removed.append(n)
        elif like(n, c["remove_other_languages"]) and cap_lang and cap_lang.lower() != lang.lower():
            removed.append(n)
    return removed, [n for n in names if n not in removed]


def select_features(enabled):
    f = plan["features"]
    return [n for n in enabled if not like(n, f["keep"]) and like(n, f["disable"])]


APPX_PRO_25H2 = [
    "Clipchamp.Clipchamp", "Microsoft.ApplicationCompatibilityEnhancements", "Microsoft.AV1VideoExtension",
    "Microsoft.AVCEncoderVideoExtension", "Microsoft.BingNews", "Microsoft.BingSearch", "Microsoft.BingWeather",
    "Microsoft.Copilot", "Microsoft.DesktopAppInstaller", "Microsoft.GamingApp", "Microsoft.GetHelp",
    "Microsoft.HEIFImageExtension", "Microsoft.HEVCVideoExtension", "Microsoft.MicrosoftOfficeHub",
    "Microsoft.MicrosoftSolitaireCollection", "Microsoft.MicrosoftStickyNotes", "Microsoft.MPEG2VideoExtension",
    "Microsoft.OutlookForWindows", "Microsoft.Paint", "Microsoft.PowerAutomateDesktop", "Microsoft.RawImageExtension",
    "Microsoft.ScreenSketch", "Microsoft.SecHealthUI", "Microsoft.StorePurchaseApp", "Microsoft.Todos",
    "Microsoft.VP9VideoExtensions", "Microsoft.WebMediaExtensions", "Microsoft.WebpImageExtension",
    "Microsoft.Windows.DevHome", "Microsoft.Windows.Photos", "Microsoft.WindowsAlarms", "Microsoft.WindowsCalculator",
    "Microsoft.WindowsCamera", "Microsoft.WindowsFeedbackHub", "Microsoft.WindowsNotepad", "Microsoft.WindowsSoundRecorder",
    "Microsoft.WindowsStore", "Microsoft.WindowsTerminal", "Microsoft.Xbox.TCUI", "Microsoft.XboxGamingOverlay",
    "Microsoft.XboxIdentityProvider", "Microsoft.XboxSpeechToTextOverlay", "Microsoft.YourPhone", "Microsoft.ZuneMusic",
    "MicrosoftCorporationII.QuickAssist", "MicrosoftWindows.Client.WebExperience", "MicrosoftWindows.CrossDevice",
    "Microsoft.VCLibs.140.00", "Microsoft.UI.Xaml.2.8", "Microsoft.WindowsAppRuntime.1.5",
]

CAPS_FR = [
    "App.StepsRecorder~~~~0.0.1.0", "Browser.InternetExplorer~~~~0.0.11.0", "DirectX.Configuration.Database~~~~0.0.1.0", "Hello.Face.20134~~~~0.0.1.0",
    "Language.Basic~~~fr-FR~0.0.1.0", "Language.Basic~~~en-US~0.0.1.0", "Language.Handwriting~~~fr-FR~0.0.1.0",
    "Language.OCR~~~fr-FR~0.0.1.0", "Language.Speech~~~fr-FR~0.0.1.0", "Language.TextToSpeech~~~fr-FR~0.0.1.0",
    "Language.TextToSpeech~~~en-US~0.0.1.0", "Language.Fonts.Jpan~~~und-JPAN~0.0.1.0", "Language.Fonts.Kore~~~und-KORE~0.0.1.0",
    "MathRecognizer~~~~0.0.1.0", "Media.WindowsMediaPlayer~~~~0.0.12.0", "Microsoft.Wallpapers.Extended~~~~0.0.1.0",
    "Microsoft.Windows.Ethernet.Client.Intel.E1i68x64~~~~0.0.1.0", "Microsoft.Windows.Ethernet.Client.Realtek.Rtcx21x64~~~~0.0.1.0",
    "Microsoft.Windows.Wifi.Client.Intel.Netwtw14~~~~0.0.1.0", "Microsoft.Windows.MSPaint~~~~0.0.1.0",
    "Microsoft.Windows.Notepad.System~~~~0.0.1.0", "Microsoft.Windows.PowerShell.ISE~~~~0.0.1.0",
    "Microsoft.Windows.Sense.Client~~~~", "Microsoft.Windows.SnippingTool~~~~0.0.1.0", "OneCoreUAP.OneSync~~~~0.0.1.0",
    "OpenSSH.Client~~~~0.0.1.0", "Print.Management.Console~~~~0.0.1.0", "VBSCRIPT~~~~", "WMIC~~~~",
    "Windows.Kernel.LA57~~~~0.0.1.0", "Windows.Client.ShellComponents~~~~0.0.1.0", "NetFX3~~~~",
]

FEATURES_ENABLED = [
    "Printing-PrintToPDFServices-Features", "Printing-XPSServices-Features", "SearchEngine-Client-Package",
    "MSRDC-Infrastructure", "TIFFIFilter", "LegacyComponents", "DirectPlay", "Printing-Foundation-Features",
    "Printing-Foundation-InternetPrinting-Client", "MediaPlayback", "WindowsMediaPlayer", "SMB1Protocol",
    "SMB1Protocol-Client", "SMB1Protocol-Deprecation", "WCF-Services45", "WCF-TCP-PortSharing45", "NetFx4-AdvSrvs",
    "MicrosoftWindowsPowerShellV2Root", "MicrosoftWindowsPowerShellV2", "WorkFolders-Client",
    "Windows-Defender-Default-Definitions", "Microsoft-RemoteDesktopConnection", "Recall", "Microsoft-Hyper-V-All",
    "VirtualMachinePlatform", "HypervisorPlatform", "Containers-DisposableClientVM",
]

SECURITY_SERVICES = ["WinDefend", "WdNisSvc", "WdFilter", "WdBoot", "SecurityHealthService", "mpssvc", "BFE",
                     "TPM", "hvservice", "vgc", "vgk", "EasyAntiCheat", "EasyAntiCheat_EOS", "BEService", "BEDaisy"]


class Structure(unittest.TestCase):
    def test_sections(self):
        self.assertEqual(plan["schema"], 1)
        for k in ("appx", "capabilities", "features", "drivers", "services", "registry", "files_remove"):
            self.assertIn(k, plan)
            self.assertIn("doc", plan[k], k)
        self.assertEqual(set(plan["features"]), {"doc", "disable", "enable_from_source", "keep"})

    def test_registry_entries(self):
        types = {"DWord", "QWord", "String", "ExpandString", "MultiString"}
        for e in plan["registry"]["set"]:
            self.assertIn(e["hive"], ("SYSTEM", "SOFTWARE", "DEFAULT"), e)
            self.assertIn(e["type"], types, e)
            self.assertTrue(e["why"], e)
            if e["hive"] == "SYSTEM":
                self.assertTrue(e["path"].startswith("{CS}\\"), e)
            else:
                self.assertNotIn("{CS}", e["path"], e)
            if e["type"] == "DWord":
                self.assertIsInstance(e["value"], int, e)
                self.assertTrue(0 <= e["value"] <= 0x7FFFFFFF, e)
            if e["type"] == "QWord":
                self.assertIsInstance(e["value"], int, e)
            if e["type"] in ("String", "ExpandString"):
                self.assertIsInstance(e["value"], str, e)
        keys = [(e["hive"], e["path"].lower(), e["name"].lower()) for e in plan["registry"]["set"]]
        self.assertEqual(len(keys), len(set(keys)), "valeur posée deux fois")

    def test_files_remove_relative_and_bounded(self):
        allowed = ("Windows\\System32\\Recovery\\Winre.wim", "Windows\\WinSxS\\Backup\\", "Windows\\WinSxS\\ManifestCache\\",
                   "Windows\\WinSxS\\Temp\\PendingDeletes\\", "Windows\\Logs\\", "Windows\\Temp\\", "Windows\\Panther\\",
                   "Windows\\SoftwareDistribution\\Download\\", "ProgramData\\Microsoft\\Windows\\WER\\")
        for p in plan["files_remove"]["paths"]:
            self.assertFalse(p.startswith("\\") or ":" in p or ".." in p, p)
            self.assertTrue(p.startswith(allowed), "chemin hors liste blanche : " + p)
            self.assertNotEqual(p.rstrip("\\*"), "Windows\\WinSxS", "purge totale de WinSxS refusée")


class SecurityFloor(unittest.TestCase):
    def test_no_protected_service_disabled(self):
        protected = plan["services"]["never_touch"]
        for s in plan["services"]["disable"]:
            self.assertFalse(like(s["name"], protected), s["name"])
            self.assertTrue(s["why"], s)
        for n in SECURITY_SERVICES:
            self.assertTrue(like(n, protected), "service de sécurité / anti-triche absent de never_touch : " + n)
            self.assertFalse(like(n, [s["name"] for s in plan["services"]["disable"]]), n)

    def _get(self, path, name):
        hits = [e for e in plan["registry"]["set"] if e["hive"] == "SYSTEM" and e["path"] == path and e["name"] == name]
        self.assertEqual(len(hits), 1, path + "\\" + name)
        return hits[0]["value"]

    def test_vbs_hvci_baseline(self):
        dg = "{CS}\\Control\\DeviceGuard"
        self.assertEqual(self._get(dg, "EnableVirtualizationBasedSecurity"), 1)
        self.assertIn(self._get(dg, "RequirePlatformSecurityFeatures"), (1, 3))
        self.assertEqual(self._get(dg, "Locked"), 0, "verrou UEFI : perf ne pourrait plus couper l'hyperviseur")
        hv = dg + "\\Scenarios\\HypervisorEnforcedCodeIntegrity"
        self.assertEqual(self._get(hv, "Enabled"), 1)
        self.assertEqual(self._get(hv, "Locked"), 0)
        self.assertEqual(self._get("{CS}\\Control\\CI\\Config", "VulnerableDriverBlocklistEnable"), 1)

    def test_nothing_weakens_security(self):
        for e in plan["registry"]["set"] + plan["registry"]["delete"]:
            p = e["path"].lower()
            self.assertNotIn("windows defender", p, e)
            self.assertNotIn("\\services\\", p, "les services passent par services.disable : %r" % e)
            self.assertNotIn("kernelshadowstacks", p, "protection de pile du noyau : jamais touchée")
            self.assertNotIn("securityhealth", p, e)
            self.assertNotIn("firewall", p, e)
            if "deviceguard" in p:
                self.assertFalse(e["name"].lower().startswith("disable"), e)
            self.assertNotIn("\\lsa", p, e)

    def test_same_baseline_as_rago_security(self):
        with open(SECURITY_PS1, encoding="utf-8-sig") as f:
            ps = f.read()
        found = re.findall(r"@\{ Path = (\$DG|\"\$DG\\[^\"]+\"|'[^']+'); Name = '(\w+)'; Value = (\d+) \}", ps)
        self.assertEqual(len(found), 6, found)
        dg = "{CS}\\Control\\DeviceGuard"
        for path, name, value in found:
            if path == "$DG":
                path = dg
            elif path.startswith('"$DG\\'):
                path = dg + path[4:-1]
            else:
                path = path.strip("'").replace("HKLM:\\SYSTEM\\CurrentControlSet", "{CS}")
            self.assertEqual(self._get(path, name), int(value), (path, name))


class Selection(unittest.TestCase):
    def test_appx(self):
        removed, kept = select_appx(APPX_PRO_25H2)
        for k in ("Microsoft.SecHealthUI", "Microsoft.VCLibs.140.00", "Microsoft.UI.Xaml.2.8", "Microsoft.WindowsAppRuntime.1.5",
                  "Microsoft.HEVCVideoExtension", "Microsoft.AV1VideoExtension", "Microsoft.VP9VideoExtensions"):
            self.assertIn(k, kept, k)
        for r in ("Microsoft.WindowsStore", "Microsoft.GamingApp", "Microsoft.Copilot", "MicrosoftWindows.Client.WebExperience",
                  "Microsoft.BingNews", "Microsoft.YourPhone", "Clipchamp.Clipchamp", "Microsoft.OutlookForWindows"):
            self.assertIn(r, removed, r)

    def test_capabilities_main_language_kept(self):
        removed, kept = select_caps(CAPS_FR, "fr-FR")
        for k in ("Language.Basic~~~fr-FR~0.0.1.0", "Language.TextToSpeech~~~fr-FR~0.0.1.0", "Language.Fonts.Jpan~~~und-JPAN~0.0.1.0",
                  "Language.Fonts.Kore~~~und-KORE~0.0.1.0", "DirectX.Configuration.Database~~~~0.0.1.0", "NetFX3~~~~",
                  "Microsoft.Windows.Ethernet.Client.Intel.E1i68x64~~~~0.0.1.0", "Microsoft.Windows.Wifi.Client.Intel.Netwtw14~~~~0.0.1.0",
                  "Microsoft.Windows.Sense.Client~~~~", "Windows.Kernel.LA57~~~~0.0.1.0", "Microsoft.Windows.Notepad.System~~~~0.0.1.0",
                  "VBSCRIPT~~~~", "WMIC~~~~", "Media.WindowsMediaPlayer~~~~0.0.12.0"):
            self.assertIn(k, kept, k)
        # FOD préinstallées que Microsoft dit de ne pas retirer (« Available Features on Demand »).
        for k in ("Browser.InternetExplorer~~~~0.0.11.0", "OpenSSH.Client~~~~0.0.1.0", "MathRecognizer~~~~0.0.1.0",
                  "Microsoft.Wallpapers.Extended~~~~0.0.1.0", "OneCoreUAP.OneSync~~~~0.0.1.0",
                  "Microsoft.Windows.PowerShell.ISE~~~~0.0.1.0", "Print.Management.Console~~~~0.0.1.0",
                  "App.StepsRecorder~~~~0.0.1.0"):
            self.assertIn(k, kept, k)
        for r in ("Language.Basic~~~en-US~0.0.1.0", "Language.TextToSpeech~~~en-US~0.0.1.0", "Hello.Face.20134~~~~0.0.1.0",
                  "Microsoft.Windows.MSPaint~~~~0.0.1.0", "Microsoft.Windows.SnippingTool~~~~0.0.1.0",
                  "Language.Handwriting~~~fr-FR~0.0.1.0", "Language.OCR~~~fr-FR~0.0.1.0", "Language.Speech~~~fr-FR~0.0.1.0"):
            self.assertIn(r, removed, r)

    def test_capabilities_other_language(self):
        removed, kept = select_caps(CAPS_FR, "en-US")
        self.assertIn("Language.Basic~~~fr-FR~0.0.1.0", removed)
        self.assertIn("Language.Basic~~~en-US~0.0.1.0", kept)

    def test_features(self):
        off = select_features(FEATURES_ENABLED)
        for k in ("MediaPlayback", "DirectPlay", "LegacyComponents", "NetFx4-AdvSrvs", "WCF-Services45",
                  "Windows-Defender-Default-Definitions", "SearchEngine-Client-Package", "Microsoft-Hyper-V-All",
                  "VirtualMachinePlatform", "HypervisorPlatform", "Microsoft-RemoteDesktopConnection", "WindowsMediaPlayer"):
            self.assertNotIn(k, off, k)
        for r in ("SMB1Protocol", "SMB1Protocol-Client", "Printing-PrintToPDFServices-Features",
                  "MicrosoftWindowsPowerShellV2", "Recall", "WorkFolders-Client"):
            self.assertIn(r, off, r)
        self.assertEqual(plan["features"]["enable_from_source"], ["NetFx3"])

    def test_drivers_keep_essential_classes(self):
        d = plan["drivers"]
        for k in ("SCSIAdapter", "HDC", "DiskDrive", "Display", "Net", "HIDClass", "Keyboard", "Mouse", "USB",
                  "SecurityDevices", "System", "MEDIA"):
            self.assertIn(k, d["keep_classes"], k)
            self.assertNotIn(k, d["remove_oem_classes"], k)


if __name__ == "__main__":
    unittest.main()
