#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Rago OS (M5) : windows/autounattend.xml contre la référence Microsoft.

Microsoft ne publie pas de schéma XSD pour unattend.xml : la validation
officielle se fait dans Windows SIM (ADK) avec le catalogue de l'image (À FAIRE
sur Windows). Ce test vérifie ce qui peut l'être sans Windows, d'après les
pages « Unattended Windows Setup Reference » de Microsoft Learn :
  - XML bien formé, espaces de noms exacts (http, pas https) ;
  - attributs de chaque composant, passes valides, chaque réglage dans une
    passe où Microsoft l'autorise ;
  - sécurité / BYOL : aucune clé de produit, aucun effacement de disque, aucun
    contournement TPM / Secure Boot, mot de passe vide seulement ;
  - les XPath que compile_micro_engine.ps1 modifie existent une seule fois.
"""
import os
import re
import unittest
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
WIN = os.path.dirname(HERE)
UNATTEND = os.path.join(WIN, "autounattend.xml")
COMPILE = os.path.join(WIN, "compile_micro_engine.ps1")
U = "urn:schemas-microsoft-com:unattend"
WCM = "http://schemas.microsoft.com/WMIConfig/2002/State"
XSI = "http://www.w3.org/2001/XMLSchema-instance"
N = {"u": U}

PASSES = {"windowsPE", "offlineServicing", "generalize", "specialize", "auditSystem", "auditUser", "oobeSystem"}
# Composant -> passes autorisées (Microsoft Learn, pages de chaque composant / réglage).
COMPONENT_PASSES = {
    "Microsoft-Windows-International-Core-WinPE": {"windowsPE"},
    "Microsoft-Windows-Setup": {"windowsPE"},
    "Microsoft-Windows-International-Core": {"specialize", "oobeSystem"},
    "Microsoft-Windows-SQMApi": {"specialize"},
    "Microsoft-Windows-Deployment": {"specialize", "auditUser"},
}
# Réglages de Microsoft-Windows-Shell-Setup -> passes autorisées.
SHELL_SETUP = {
    "ComputerName": {"offlineServicing", "specialize"},
    "TimeZone": {"auditSystem", "oobeSystem", "specialize"},
    "OOBE": {"oobeSystem"},
    "UserAccounts": {"auditSystem", "oobeSystem"},
    "AutoLogon": {"auditSystem", "oobeSystem", "specialize"},
    "FirstLogonCommands": {"oobeSystem"},
}
OOBE_CHILDREN = {"HideEULAPage", "HideLocalAccountScreen", "HideOEMRegistrationScreen", "HideOnlineAccountScreens",
                 "HideWirelessSetupInOOBE", "NetworkLocation", "OEMAppID", "ProtectYourPC", "UnattendEnableRetailDemo",
                 "VMModeOptimizations"}

with open(UNATTEND, "rb") as f:
    RAW = f.read()
TREE = ET.fromstring(RAW)


def q(tag):
    return "{%s}%s" % (U, tag)


def components():
    for s in TREE.findall("u:settings", N):
        for c in s.findall("u:component", N):
            yield s.get("pass"), c


class WellFormed(unittest.TestCase):
    def test_root_and_namespaces(self):
        self.assertEqual(TREE.tag, q("unattend"))
        text = RAW.decode("utf-8")
        self.assertTrue(text.startswith('<?xml version="1.0" encoding="utf-8"?>'))
        self.assertNotIn("https://schemas.microsoft.com", text, "espace de noms wcm : http, pas https")
        self.assertNotIn("https://www.w3.org", text)
        self.assertEqual(text.count('xmlns:wcm="%s"' % WCM), text.count("<component "))
        self.assertEqual(text.count('xmlns:xsi="%s"' % XSI), text.count("<component "))

    def test_passes(self):
        seen = [s.get("pass") for s in TREE.findall("u:settings", N)]
        self.assertEqual(len(seen), len(set(seen)), "passe en double")
        self.assertTrue(set(seen) <= PASSES, seen)
        self.assertEqual(seen, ["windowsPE", "specialize", "oobeSystem"])

    def test_component_attributes(self):
        n = 0
        for _, c in components():
            n += 1
            self.assertEqual(c.get("processorArchitecture"), "amd64")
            self.assertEqual(c.get("publicKeyToken"), "31bf3856ad364e35")
            self.assertEqual(c.get("language"), "neutral")
            self.assertEqual(c.get("versionScope"), "nonSxS")
        self.assertEqual(n, 7)

    def test_components_in_valid_passes(self):
        names = set()
        for p, c in components():
            name = c.get("name")
            names.add((p, name))
            if name == "Microsoft-Windows-Shell-Setup":
                for child in c:
                    tag = child.tag.split("}")[1]
                    self.assertIn(tag, SHELL_SETUP, tag)
                    self.assertIn(p, SHELL_SETUP[tag], "%s pas valide en %s" % (tag, p))
            else:
                self.assertIn(name, COMPONENT_PASSES, name)
                self.assertIn(p, COMPONENT_PASSES[name], "%s pas valide en %s" % (name, p))
        self.assertEqual(len(names), len(list(components())), "composant en double dans une passe")


class Settings(unittest.TestCase):
    def comp(self, p, name):
        r = TREE.findall("u:settings[@pass='%s']/u:component[@name='%s']" % (p, name), N)
        self.assertEqual(len(r), 1, (p, name))
        return r[0]

    def test_international(self):
        lang = re.compile(r"^[a-z]{2,3}-[A-Z]{2,4}$")
        pe = self.comp("windowsPE", "Microsoft-Windows-International-Core-WinPE")
        self.assertRegex(pe.find("u:SetupUILanguage/u:UILanguage", N).text, lang)
        for c in (pe, self.comp("oobeSystem", "Microsoft-Windows-International-Core")):
            for t in ("InputLocale", "SystemLocale", "UILanguage", "UserLocale"):
                self.assertRegex(c.find("u:" + t, N).text, lang, t)

    def test_setup_no_key_no_wipe(self):
        s = self.comp("windowsPE", "Microsoft-Windows-Setup")
        self.assertEqual(s.find("u:UserData/u:AcceptEula", N).text, "true")
        self.assertIsNone(s.find("u:UserData/u:ProductKey/u:Key", N), "BYOL : aucune clé de produit dans le dépôt")
        self.assertEqual(s.find("u:UserData/u:ProductKey/u:WillShowUI", N).text, "OnError")
        self.assertIsNone(s.find("u:DiskConfiguration", N), "aucun partitionnement / effacement de disque")
        self.assertNotIn(b"WillWipeDisk", RAW)
        self.assertIsNone(s.find(".//u:InstallToAvailablePartition", N), "choisirait seule une partition : dangereux en double démarrage")
        self.assertIsNone(s.find(".//u:InstallTo", N), "InstallTo seulement si compile_micro_engine.ps1 le demande")
        md = s.findall("u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData", N)
        self.assertEqual(len(md), 1)
        self.assertEqual(md[0].get("{%s}action" % WCM), "add")
        self.assertEqual(md[0].find("u:Key", N).text, "/IMAGE/INDEX")
        self.assertEqual(md[0].find("u:Value", N).text, "1")
        self.assertEqual(s.find("u:ImageInstall/u:OSImage/u:Compact", N).text, "true")
        self.assertEqual(s.find("u:ImageInstall/u:OSImage/u:WillShowUI", N).text, "OnError")
        self.assertEqual(s.find("u:DynamicUpdate/u:Enable", N).text, "false")

    def test_no_requirement_bypass(self):
        low = RAW.decode("utf-8").lower()
        for bad in ("labconfig", "bypasstpmcheck", "bypasssecurebootcheck", "bypassramcheck", "allowupgradeswithunsupportedtpm",
                    "bypassnro", "skipmachineoobe", "skipuseroobe"):
            self.assertNotIn(bad, low, bad)

    def test_specialize(self):
        sh = self.comp("specialize", "Microsoft-Windows-Shell-Setup")
        cn = sh.find("u:ComputerName", N).text
        self.assertRegex(cn, r"^[A-Za-z0-9-]{1,15}$")
        self.assertFalse(cn.isdigit())
        self.assertTrue(sh.find("u:TimeZone", N).text)
        self.assertEqual(self.comp("specialize", "Microsoft-Windows-SQMApi").find("u:CEIPEnabled", N).text, "0")
        cmds = self.comp("specialize", "Microsoft-Windows-Deployment").findall("u:RunSynchronous/u:RunSynchronousCommand", N)
        self.assertEqual(len(cmds), 1)
        c = cmds[0]
        self.assertEqual(c.get("{%s}action" % WCM), "add")
        self.assertIsNone(c.find("u:CommandLine", N), "RunSynchronousCommand prend <Path>, pas <CommandLine>")
        path = c.find("u:Path", N).text
        self.assertLessEqual(len(path), 259, "Path : 259 caractères au plus")
        self.assertIn(r"\Rago\setup\firstboot.ps1 -Phase specialize", path)
        self.assertTrue(1 <= int(c.find("u:Order", N).text) <= 500)
        self.assertEqual(c.find("u:WillReboot", N).text, "Never")

    def test_oobe_account_autologon(self):
        sh = self.comp("oobeSystem", "Microsoft-Windows-Shell-Setup")
        oobe = sh.find("u:OOBE", N)
        for child in oobe:
            self.assertIn(child.tag.split("}")[1], OOBE_CHILDREN)
        self.assertEqual(oobe.find("u:ProtectYourPC", N).text, "3")
        self.assertEqual(oobe.find("u:HideOnlineAccountScreens", N).text, "true")
        self.assertIsNone(oobe.find("u:HideLocalAccountScreen", N), "réservé à Windows Server")
        acc = sh.findall("u:UserAccounts/u:LocalAccounts/u:LocalAccount", N)
        self.assertEqual(len(acc), 1)
        a = acc[0]
        self.assertEqual(a.get("{%s}action" % WCM), "add")
        name = a.find("u:Name", N).text
        self.assertEqual(a.find("u:Group", N).text, "Administrators", "nom anglais, neutre (doc Microsoft)")
        for pw in (a.find("u:Password/u:Value", N), sh.find("u:AutoLogon/u:Password/u:Value", N)):
            self.assertIn(pw.text, (None, ""), "aucun mot de passe dans le dépôt")
        self.assertIsNone(sh.find("u:UserAccounts/u:AdministratorPassword", N), "compte Administrateur intégré non activé")
        al = sh.find("u:AutoLogon", N)
        self.assertEqual(al.find("u:Enabled", N).text, "true")
        self.assertEqual(al.find("u:Username", N).text, name)
        self.assertNotEqual(name.lower(), "administrator")
        self.assertGreater(int(al.find("u:LogonCount", N).text), 0)


class CompileScriptXPaths(unittest.TestCase):
    """Les XPath que New-RagoUnattend modifie existent exactement une fois."""

    def test_xpaths(self):
        with open(COMPILE, encoding="utf-8-sig") as f:
            ps = f.read()
        pe = "//u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-International-Core-WinPE']"
        oobe = "//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-International-Core']"
        spec = "//u:settings[@pass='specialize']/u:component[@name='Microsoft-Windows-Shell-Setup']"
        shell = "//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']"
        for base in (pe, oobe, spec, shell):
            self.assertIn(base, ps)
        paths = [pe + "/u:SetupUILanguage/u:UILanguage", spec + "/u:ComputerName", spec + "/u:TimeZone",
                 shell + "/u:UserAccounts/u:LocalAccounts/u:LocalAccount/u:Name", shell + "/u:AutoLogon/u:Username",
                 "//u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-Setup']/u:ImageInstall/u:OSImage"]
        for c in (pe, oobe):
            paths += [c + "/u:" + t for t in ("InputLocale", "SystemLocale", "UILanguage", "UserLocale")]
        for xp in paths:
            et = "." + xp[1:]  # ElementTree : chemin relatif
            self.assertEqual(len(TREE.findall(et.replace("//u:settings", "u:settings"), N)), 1, xp)
        # InstallTo est inséré juste après InstallFrom, comme dans la référence.
        self.assertIn("InsertAfter($to, $os.SelectSingleNode('u:InstallFrom', $ns))", ps)


if __name__ == "__main__":
    unittest.main()
