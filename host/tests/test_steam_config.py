#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tests de host/proton/rago_steam_config.py (module M2).
# Sans root, sans Steam : arbres Steam / Heroic / Lutris factices, au format
# des vrais fichiers (localconfig.vdf, config.vdf, libraryfolders.vdf,
# appmanifest_*.acf, config.json de Heroic).
# Usage : python3 host/tests/test_steam_config.py
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "proton", "rago_steam_config.py")
spec = importlib.util.spec_from_file_location("rsc", SRC)
rsc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rsc)

LOCALCONFIG = '''"UserLocalConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"apps"
				{
					"730"
					{
						"LastPlayed"		"1731400000"
						"LaunchOptions"		"-novid -high"
					}
					"1091500"
					{
						"LaunchOptions"		"PROTON_LOG=1 %command% --launcher-skip"
					}
					"440"
					{
						"Playtime"		"12"
					}
				}
			}
		}
	}
	"friends"
	{
		"PersonaName"		"Joueur \\"Rago\\""
	}
}
'''

CONFIG = '''"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"AutoUpdateWindowEnabled"		"0"
			}
		}
	}
}
'''


def acf(appid, name, installdir):
    return f'''"AppState"
{{
	"appid"		"{appid}"
	"Universe"		"1"
	"name"		"{name}"
	"StateFlags"		"4"
	"installdir"		"{installdir}"
}}
'''


class Fake:
    """Un HOME avec Steam (deux bibliothèques), un compte, des jeux et des outils."""

    def __init__(self):
        self.home = tempfile.mkdtemp(prefix="rago-m2-steam-")
        self.root = os.path.join(self.home, ".local/share/Steam")
        self.lib2 = os.path.join(self.home, "Jeux/Steam Library")
        for d in (self.root + "/steamapps/common", self.lib2 + "/steamapps/common", self.root + "/config",
                  self.root + "/userdata/12345678/config", self.root + "/ubuntu12_32"):
            os.makedirs(d)
        with open(self.root + "/steamapps/libraryfolders.vdf", "w") as f:
            f.write(f'''"libraryfolders"
{{
	"0"
	{{
		"path"		"{self.root}"
		"apps"
		{{
			"730"		"1"
		}}
	}}
	"1"
	{{
		"path"		"{self.lib2}"
	}}
}}
''')
        apps = [
            (self.root, "730", "Counter-Strike 2", "Counter-Strike Global Offensive"),
            (self.root, "440", "Team Fortress 2", "Team Fortress 2"),
            (self.root, "1628350", "Steam Linux Runtime 3.0 (sniper)", "SteamLinuxRuntime_sniper"),
            (self.root, "2805730", "Proton 9.0", "Proton 9.0"),
            (self.lib2, "1091500", "Cyberpunk 2077", "Cyberpunk 2077"),
            (self.lib2, "1826330", "Proton EasyAntiCheat Runtime", "Proton EasyAntiCheat Runtime"),
            (self.lib2, "3600000", "Proton 11.0 (Beta)", "Proton 11.0"),
        ]
        for lib, appid, name, inst in apps:
            with open(f"{lib}/steamapps/appmanifest_{appid}.acf", "w") as f:
                f.write(acf(appid, name, inst))
            os.makedirs(f"{lib}/steamapps/common/{inst}", exist_ok=True)
        self.lc = self.root + "/userdata/12345678/config/localconfig.vdf"
        with open(self.lc, "w") as f:
            f.write(LOCALCONFIG)
        self.cfg = self.root + "/config/config.vdf"
        with open(self.cfg, "w") as f:
            f.write(CONFIG)
        os.makedirs(self.home + "/.steam")
        os.symlink(self.root, self.home + "/.steam/root")
        self.env = dict(os.environ, HOME=self.home, XDG_STATE_HOME=self.home + "/.local/state",
                        XDG_CONFIG_HOME=self.home + "/.config")

    def run(self, *args):
        p = subprocess.run([sys.executable, SRC, *args], env=self.env, capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr

    def opts(self, appid, path=None):
        tree = rsc.vdf_loads(rsc.read_text(path or self.lc))
        node = rsc.vdf_child(rsc.vdf_path(tree, rsc.APPS_PATH), appid)
        return None if node is None else rsc.vdf_get(node, "LaunchOptions")

    def default_tool(self):
        m = rsc.vdf_path(rsc.vdf_loads(rsc.read_text(self.cfg)), rsc.COMPAT_PATH)
        n = rsc.vdf_child(m, "0") if m is not None else None
        return None if n is None else rsc.vdf_get(n, "name")

    def edit_opts(self, appid, value):
        tree = rsc.vdf_loads(rsc.read_text(self.lc))
        rsc.vdf_set(rsc.vdf_child(rsc.vdf_path(tree, rsc.APPS_PATH), appid, True), "LaunchOptions", value)
        with open(self.lc, "w") as f:
            f.write(rsc.vdf_dumps(tree))

    def close(self):
        shutil.rmtree(self.home, ignore_errors=True)


class VdfTest(unittest.TestCase):
    def test_roundtrip_keeps_order_values_and_escapes(self):
        t = rsc.vdf_loads(LOCALCONFIG)
        again = rsc.vdf_loads(rsc.vdf_dumps(t))
        self.assertEqual(t, again)
        self.assertEqual(rsc.vdf_get(rsc.vdf_get(t[0][1], "friends"), "PersonaName"), 'Joueur "Rago"')
        self.assertIn('"Joueur \\"Rago\\""', rsc.vdf_dumps(t))

    def test_case_insensitive_keys(self):
        t = rsc.vdf_loads('"a" { "Software" { "VALVE" { "steam" { "x" "1" } } } }')
        self.assertEqual(rsc.vdf_get(rsc.vdf_path(t, ("A", "software", "valve", "Steam")), "X"), "1")

    def test_comments_unquoted_and_conditions(self):
        t = rsc.vdf_loads('// tête\n"r" { k v // fin\n "c" "1" [$WIN32] }')
        self.assertEqual(rsc.vdf_get(rsc.vdf_get(t, "r"), "k"), "v")
        self.assertEqual(rsc.vdf_get(t, "r")[1][2], "[$WIN32]")
        self.assertEqual(rsc.vdf_loads(rsc.vdf_dumps(t)), t)

    def test_broken_files_are_refused(self):
        for bad in ('"a" { "b" "c"', '"a" "b" }', '"a', '{ "x" "y" }'):
            with self.assertRaises(rsc.VdfError, msg=bad):
                rsc.vdf_loads(bad)


class HookTest(unittest.TestCase):
    def test_hook_rules(self):
        h = rsc.hook_options
        self.assertEqual(h(""), "rago-launch %command%")
        self.assertEqual(h("   "), "rago-launch %command%")
        self.assertEqual(h("-novid -high"), "rago-launch %command% -novid -high")
        self.assertEqual(h("PROTON_LOG=1 %command% -x"), "PROTON_LOG=1 rago-launch %command% -x")
        self.assertEqual(h("gamemoderun %command%"), "gamemoderun rago-launch %command%")
        self.assertEqual(h("rago-launch %command%"), "rago-launch %command%")
        self.assertEqual(h("/usr/bin/rago-launch %command%"), "/usr/bin/rago-launch %command%")

    def test_hook_detection_is_a_whole_word(self):
        self.assertFalse(rsc.has_hook("not-rago-launch %command%"))
        self.assertFalse(rsc.has_hook("rago-launcher %command%"))
        self.assertTrue(rsc.has_hook("FOO=1 rago-launch %command%"))

    def test_unhook_rules(self):
        u = rsc.unhook_options
        self.assertEqual(u("rago-launch %command%"), "")
        self.assertEqual(u("PROTON_LOG=1 rago-launch %command% -x"), "PROTON_LOG=1 %command% -x")
        self.assertEqual(u("rago-launch %command% -novid"), "%command% -novid")
        self.assertEqual(u("-novid"), "-novid")
        # Aller-retour : identique, ou équivalent pour Steam (« %command% -novid » = « -novid »).
        for o in ("", "A=1 %command% -b", "gamemoderun %command%"):
            self.assertEqual(u(rsc.hook_options(o)), o)
        self.assertEqual(u(rsc.hook_options("-novid")), "%command% -novid")


class SteamTest(unittest.TestCase):
    def setUp(self):
        self.f = Fake()

    def tearDown(self):
        self.f.close()

    def test_sync_hooks_every_game_but_not_tools(self):
        rc, _, err = self.f.run("sync")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.f.opts("730"), "rago-launch %command% -novid -high")
        self.assertEqual(self.f.opts("1091500"), "PROTON_LOG=1 rago-launch %command% --launcher-skip")
        self.assertEqual(self.f.opts("440"), "rago-launch %command%")
        for tool in ("1628350", "2805730", "1826330", "3600000"):
            self.assertIsNone(self.f.opts(tool), tool)
        # Le reste du fichier est intact.
        t = rsc.vdf_loads(rsc.read_text(self.f.lc))
        self.assertEqual(rsc.vdf_get(rsc.vdf_get(t[0][1], "friends"), "PersonaName"), 'Joueur "Rago"')
        self.assertTrue(os.path.exists(self.f.lc + ".rago-bak"))
        with open(self.f.lc + ".rago-bak") as fh:
            self.assertEqual(fh.read(), LOCALCONFIG)

    def test_sync_is_idempotent(self):
        self.f.run("sync")
        before = rsc.read_text(self.f.lc)
        st = os.stat(self.f.lc).st_mtime_ns
        time.sleep(0.01)
        rc, _, err = self.f.run("sync")
        self.assertEqual(rc, 0)
        self.assertEqual(rsc.read_text(self.f.lc), before)
        self.assertEqual(os.stat(self.f.lc).st_mtime_ns, st, "fichier réécrit sans raison")
        self.assertIn("0 jeu(x) branché(s), 3 déjà", err)

    def test_hook_removed_by_hand_is_never_put_back(self):
        self.f.run("sync")
        self.f.edit_opts("730", "-novid")
        rc, _, err = self.f.run("sync")
        self.assertEqual(rc, 0)
        self.assertEqual(self.f.opts("730"), "-novid")
        self.assertIn("retiré à la main", err)
        self.f.run("sync")
        self.assertEqual(self.f.opts("730"), "-novid")

    def test_unsync_restores_the_original_options(self):
        self.f.run("sync", "--default-tool", "GE-Proton10-30")
        self.f.edit_opts("440", "rago-launch %command% -console")  # changé par le joueur depuis
        rc, _, err = self.f.run("unsync")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.f.opts("730"), "-novid -high")
        self.assertEqual(self.f.opts("1091500"), "PROTON_LOG=1 %command% --launcher-skip")
        self.assertEqual(self.f.opts("440"), "%command% -console")
        self.assertIsNone(self.f.default_tool())

    def test_default_tool_only_when_the_player_has_none(self):
        rc, _, err = self.f.run("sync", "--default-tool", "GE-Proton10-30")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.f.default_tool(), "GE-Proton10-30")
        m = rsc.vdf_child(rsc.vdf_path(rsc.vdf_loads(rsc.read_text(self.f.cfg)), rsc.COMPAT_PATH), "0")
        self.assertEqual(rsc.vdf_get(m, "priority"), "75")
        # Nouvelle version épinglée : notre choix suit.
        self.f.run("sync", "--default-tool", "GE-Proton10-31")
        self.assertEqual(self.f.default_tool(), "GE-Proton10-31")
        # Le joueur choisit Proton Experimental : gardé, et plus jamais touché.
        t = rsc.vdf_loads(rsc.read_text(self.f.cfg))
        rsc.vdf_set(rsc.vdf_child(rsc.vdf_path(t, rsc.COMPAT_PATH), "0"), "name", "proton_experimental")
        with open(self.f.cfg, "w") as fh:
            fh.write(rsc.vdf_dumps(t))
        rc, _, err = self.f.run("sync", "--default-tool", "GE-Proton10-32")
        self.assertEqual(self.f.default_tool(), "proton_experimental")
        self.assertIn("choisi par le joueur", err)
        self.f.run("unsync")
        self.assertEqual(self.f.default_tool(), "proton_experimental")

    def test_runtimes_are_found_and_written_for_rago_launch(self):
        rc, out, _ = self.f.run("runtimes")
        self.assertEqual(rc, 0)
        self.assertIn(f"PROTON_EAC_RUNTIME={self.f.lib2}/steamapps/common/Proton EasyAntiCheat Runtime", out)
        self.assertNotIn("BATTLEYE", out)
        self.f.run("sync")
        env = self.f.home + "/.local/state/rago/proton-runtimes.env"
        with open(env) as fh:
            self.assertIn(f'PROTON_EAC_RUNTIME="{self.f.lib2}/steamapps/common/Proton EasyAntiCheat Runtime"', fh.read())

    def test_status(self):
        self.f.run("sync")
        self.f.edit_opts("730", "")
        self.f.run("sync")
        rc, out, _ = self.f.run("status", "--json")
        self.assertEqual(rc, 0)
        r = json.loads(out)
        self.assertEqual(r["games"], 3)
        self.assertEqual(r["users"]["12345678"], {"hooked": 2, "not_hooked": 1, "optout": 1})

    def test_steam_running_means_nothing_is_written(self):
        d = tempfile.mkdtemp()
        steam = os.path.join(d, "steam")
        shutil.copy("/bin/sleep", steam)
        p = subprocess.Popen([steam, "30"])
        try:
            time.sleep(0.2)
            rc, _, err = self.f.run("sync")
            self.assertEqual(rc, rsc.EXIT_RUNNING, err)
            self.assertEqual(self.f.opts("730"), "-novid -high")
        finally:
            p.kill()
            p.wait()
            shutil.rmtree(d)

    def test_no_steam(self):
        shutil.rmtree(self.f.home + "/.steam")
        shutil.rmtree(self.f.home + "/.local/share/Steam")
        rc, _, err = self.f.run("sync")
        self.assertEqual(rc, rsc.EXIT_MISSING)
        self.assertIn("Steam introuvable", err)

    def test_debian_steam_installer_root(self):
        os.unlink(self.f.home + "/.steam/root")
        deb = self.f.home + "/.steam/debian-installation"
        shutil.move(self.f.home + "/.local/share/Steam", deb)
        self.assertEqual(rsc.steam_root(home=self.f.home), os.path.realpath(deb))

    def test_broken_localconfig_is_skipped(self):
        with open(self.f.lc, "w") as fh:
            fh.write('"UserLocalConfigStore" { "apps" ')
        rc, _, err = self.f.run("sync")
        self.assertEqual(rc, 0)
        self.assertIn("illisible", err)
        with open(self.f.lc) as fh:
            self.assertEqual(fh.read(), '"UserLocalConfigStore" { "apps" ')

    def test_dry_run_writes_nothing(self):
        before = rsc.read_text(self.f.lc)
        rc, _, err = self.f.run("sync", "--dry-run", "--default-tool", "GE-Proton10-30")
        self.assertEqual(rc, 0)
        self.assertEqual(rsc.read_text(self.f.lc), before)
        self.assertIsNone(self.f.default_tool())
        self.assertFalse(os.path.exists(self.f.home + "/.local/state/rago/steam-hook.json"))


class HeroicLutrisTest(unittest.TestCase):
    def setUp(self):
        self.f = Fake()
        self.h = self.f.home + "/.config/heroic"
        os.makedirs(self.h + "/GamesConfig")
        with open(self.h + "/config.json", "w") as fh:
            json.dump({"defaultSettings": {"wrapperOptions": [{"exe": "obs-gamecapture", "args": ""}], "useGameMode": False},
                       "version": "v0"}, fh)
        with open(self.h + "/GamesConfig/Fortnite.json", "w") as fh:
            json.dump({"Fortnite": {"wineVersion": {"name": "GE-Proton10-30"}}, "version": "v0", "explicit": True}, fh)

    def tearDown(self):
        self.f.close()

    def load(self, p):
        with open(p) as fh:
            return json.load(fh)

    def test_heroic_wrapper_added_first_then_removed(self):
        rc, _, err = self.f.run("heroic", "--hook", "/usr/bin/rago-launch")
        self.assertEqual(rc, 0, err)
        d = self.load(self.h + "/config.json")
        self.assertEqual(d["defaultSettings"]["wrapperOptions"][0], {"exe": "/usr/bin/rago-launch", "args": ""})
        self.assertEqual(d["defaultSettings"]["wrapperOptions"][1]["exe"], "obs-gamecapture")
        g = self.load(self.h + "/GamesConfig/Fortnite.json")
        self.assertEqual(g["Fortnite"]["wrapperOptions"], [{"exe": "/usr/bin/rago-launch", "args": ""}])
        self.assertEqual(g["version"], "v0")
        self.f.run("heroic", "--hook", "/usr/bin/rago-launch")
        self.assertEqual(len(self.load(self.h + "/config.json")["defaultSettings"]["wrapperOptions"]), 2)
        rc, _, _ = self.f.run("heroic", "--remove", "--hook", "/usr/bin/rago-launch")
        self.assertEqual(rc, 0)
        self.assertEqual(self.load(self.h + "/config.json")["defaultSettings"]["wrapperOptions"], [{"exe": "obs-gamecapture", "args": ""}])
        self.assertEqual(self.load(self.h + "/GamesConfig/Fortnite.json")["Fortnite"]["wrapperOptions"], [])

    def test_heroic_never_started(self):
        shutil.rmtree(self.h)
        rc, _, _ = self.f.run("heroic")
        self.assertEqual(rc, rsc.EXIT_MISSING)

    @unittest.skipUnless(importlib.util.find_spec("yaml"), "module yaml absent (Lutris en dépend)")
    def test_lutris_prefix(self):
        import yaml
        os.makedirs(self.f.home + "/.config/lutris")
        p = self.f.home + "/.config/lutris/system.yml"
        with open(p, "w") as fh:
            fh.write("system:\n  prefix_command: obs-gamecapture\n  disable_screen_saver: true\n")
        rc, _, err = self.f.run("lutris")
        self.assertEqual(rc, 0, err)
        with open(p) as fh:
            self.assertEqual(yaml.safe_load(fh)["system"]["prefix_command"], "rago-launch obs-gamecapture")
        self.f.run("lutris", "--remove")
        with open(p) as fh:
            d = yaml.safe_load(fh)
        self.assertEqual(d["system"]["prefix_command"], "obs-gamecapture")
        self.assertTrue(d["system"]["disable_screen_saver"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
