// SPDX-License-Identifier: GPL-2.0
//
// Tests d'intégration de rago-profiled (M14) : le vrai binaire, démon et
// launcher, sur une fausse racine (cpufreq, THP, cpuidle, ligne de commande,
// conf M1, fichier PM QoS). Le jeu est un script qui relève l'état du système
// PENDANT qu'il tourne ; le test vérifie l'état APRÈS.
//
// Le test de bout en bout avec M0 lance le vrai rago-sched-hint contre le vrai
// serveur du canal M0 (rago-common, sink en mémoire à la place des maps BPF).
// Il faut donc que rago-sched-hint soit compilé : `cargo build -p rago-sched-hint`
// (fait par `cargo test --workspace` ou daemons/rago-profiled/tests/run_tests.sh).

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use rago_common::server::{self, MemorySink, ServerConfig, ServerState};
use rago_common::{CpuSet, Topology, TopologyKind};

const CPUFREQ: &str = "sys/devices/system/cpu/cpufreq";
const THP: &str = "sys/kernel/mm/transparent_hugepage/enabled";

fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_rago-profiled"))
}

fn wait_until(limit: Duration, f: impl Fn() -> bool) -> bool {
    let t = Instant::now();
    while t.elapsed() < limit {
        if f() {
            return true;
        }
        thread::sleep(Duration::from_millis(20));
    }
    f()
}

struct Fake {
    dir: tempfile::TempDir,
}

impl Fake {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let r = dir.path();
        for i in 0..2 {
            let d = r.join(CPUFREQ).join(format!("policy{i}"));
            fs::create_dir_all(&d).unwrap();
            fs::write(d.join("scaling_governor"), "performance\n").unwrap();
            fs::write(
                d.join("scaling_available_governors"),
                "performance powersave\n",
            )
            .unwrap();
        }
        fs::create_dir_all(r.join(THP).parent().unwrap()).unwrap();
        fs::write(r.join(THP), "always [madvise] never\n").unwrap();
        let c1 = r.join("sys/devices/system/cpu/cpu0/cpuidle/state1/latency");
        fs::create_dir_all(c1.parent().unwrap()).unwrap();
        fs::write(c1, "2\n").unwrap();
        fs::create_dir_all(r.join("proc")).unwrap();
        fs::write(r.join("proc/cmdline"), "root=/dev/x quiet threadirqs\n").unwrap();
        fs::create_dir_all(r.join("etc/rago")).unwrap();
        fs::write(
            r.join("etc/rago/host-tuning.conf"),
            "RAGO_CSTATES=\"deep\"\n",
        )
        .unwrap();
        fs::create_dir_all(r.join("dev")).unwrap();
        fs::write(
            r.join("dev/cpu_dma_latency"),
            2_000_000_000i32.to_ne_bytes(),
        )
        .unwrap();
        for d in ["hooks", "profiles", "run", "out"] {
            fs::create_dir_all(r.join(d)).unwrap();
        }
        fs::write(
            r.join("profiles/jeu-a.toml"),
            r#"schema = 1
id = "jeu-a"
name = "Jeu A"
couche = "proton"
cpu_governor = "powersave"
thp = "always"
cstates = "shallow"
[match]
steam_appid = [4242]
exe = ["JeuA.exe"]
[sched_hint]
confine = "off"
render_comm = ["GameThread"]
"#,
        )
        .unwrap();
        fs::write(
            r.join("profiles/jeu-switch.json"),
            r#"{"schema":1,"id":"jeu-switch","name":"AC","couche":"switch","windows_security":"perf"}"#,
        )
        .unwrap();
        Self { dir }
    }

    fn root(&self) -> &Path {
        self.dir.path()
    }

    fn p(&self, rel: &str) -> PathBuf {
        self.root().join(rel)
    }

    fn sock(&self) -> PathBuf {
        self.p("run/profiled.sock")
    }

    fn gov(&self, i: usize) -> String {
        fs::read_to_string(self.p(CPUFREQ).join(format!("policy{i}/scaling_governor")))
            .unwrap()
            .trim()
            .to_string()
    }

    fn thp(&self) -> String {
        let s = fs::read_to_string(self.p(THP)).unwrap();
        match (s.find('['), s.find(']')) {
            (Some(a), Some(b)) => s[a + 1..b].to_string(),
            _ => s.trim().to_string(),
        }
    }

    fn out(&self, name: &str) -> String {
        fs::read_to_string(self.p("out").join(name))
            .unwrap_or_default()
            .trim()
            .to_string()
    }

    /// `rago-profiled` avec le socket et les profils de cette fausse racine.
    fn cmd(&self) -> Command {
        let mut c = Command::new(bin());
        c.arg("--socket")
            .arg(self.sock())
            .arg("--profiles-dir")
            .arg(self.p("profiles"));
        c.env_remove("SteamAppId").env_remove("SteamGameId");
        c
    }

    /// Script de jeu : relève gouverneur, THP et PM QoS pendant le jeu.
    fn game(&self, tail: &str) -> Vec<String> {
        let o = self.p("out");
        vec![
            "sh".into(),
            "-c".into(),
            format!(
                "echo $$ > {o}/pid; cat {g} > {o}/gov; cat {t} > {o}/thp; cp {q} {o}/pmqos; {tail}",
                o = o.display(),
                g = self.p(CPUFREQ).join("policy0/scaling_governor").display(),
                t = self.p(THP).display(),
                q = self.p("dev/cpu_dma_latency").display(),
            ),
        ]
    }

    fn pmqos_seen(&self) -> i32 {
        let b = fs::read(self.p("out/pmqos")).unwrap();
        i32::from_ne_bytes(b[..4].try_into().unwrap())
    }
}

struct Daemon {
    child: Option<Child>,
    log: PathBuf,
}

impl Daemon {
    fn start(f: &Fake) -> Self {
        let log = f.p("out/daemon.log");
        let err = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log)
            .unwrap();
        let child = f
            .cmd()
            .args(["daemon", "--group", ""])
            .arg("--state-dir")
            .arg(f.p("run"))
            .arg("--hooks-dir")
            .arg(f.p("hooks"))
            .arg("--root")
            .arg(f.root())
            .arg("--pmqos-dev")
            .arg(f.p("dev/cpu_dma_latency"))
            .stderr(Stdio::from(err))
            .spawn()
            .unwrap();
        let sock = f.sock();
        assert!(
            wait_until(Duration::from_secs(10), || {
                std::os::unix::net::UnixStream::connect(&sock).is_ok()
            }),
            "le démon ne répond pas"
        );
        Self {
            child: Some(child),
            log,
        }
    }

    fn log(&self) -> String {
        fs::read_to_string(&self.log).unwrap_or_default()
    }

    fn signal(&mut self, sig: i32) -> std::process::ExitStatus {
        let mut c = self.child.take().unwrap();
        // SAFETY: simple envoi de signal au démon de test.
        unsafe {
            libc::kill(c.id() as i32, sig);
        }
        c.wait().unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

fn kill_pid(pid: &str) {
    if let Ok(p) = pid.parse::<i32>() {
        // SAFETY: arrêt du faux jeu.
        unsafe {
            libc::kill(p, libc::SIGKILL);
        }
    }
}

#[test]
fn launch_applies_the_profile_during_the_game_and_restores_after() {
    let f = Fake::new();
    let d = Daemon::start(&f);
    let out = f
        .cmd()
        .args(["launch", "--id", "jeu-a", "--no-sched-hint", "--"])
        .args(f.game("exit 7"))
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(7), "code du jeu transmis : {err}");
    // Pendant le jeu.
    assert_eq!(f.out("gov"), "powersave", "{err}");
    assert_eq!(f.out("thp").trim(), "always");
    assert_eq!(f.pmqos_seen(), 2, "shallow = latence de C1");
    // Après le jeu : base exacte.
    assert_eq!(f.gov(0), "performance");
    assert_eq!(f.gov(1), "performance");
    assert_eq!(f.thp(), "madvise");
    assert!(!f.p("run/applied.json").exists());
    assert!(err.contains("profil « jeu-a »"), "{err}");
    assert!(err.contains("réglage de base remis"), "{err}");
    assert!(d.log().contains("session 1"), "{}", d.log());
}

#[test]
fn steam_appid_from_env_and_exe_from_the_command() {
    let f = Fake::new();
    let _d = Daemon::start(&f);
    // Option de lancement Steam : rago-profiled launch -- %command%
    let out = f
        .cmd()
        .env("SteamAppId", "4242")
        .args(["launch", "--no-sched-hint", "--"])
        .args(f.game("true"))
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_eq!(f.out("gov"), "powersave");
    assert!(String::from_utf8_lossy(&out.stderr).contains("trouvé par steam_appid"));
    // Proton : l'exécutable .exe de la commande désigne le jeu.
    let mut g = f.game("true");
    g.push("x".into());
    g.push(r"Z:\jeux\JEUA.EXE".into());
    let out = f
        .cmd()
        .args(["launch", "--no-sched-hint", "--"])
        .args(g)
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("trouvé par exe"));
    assert_eq!(f.gov(0), "performance");
}

#[test]
fn unknown_game_gets_the_safe_fallback_and_nothing_changes() {
    let f = Fake::new();
    let _d = Daemon::start(&f);
    let out = f
        .cmd()
        .args(["launch", "--id", "inconnu", "--no-sched-hint", "--"])
        .args(f.game("true"))
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{err}");
    assert!(err.contains("profil sûr par défaut"), "{err}");
    assert_eq!(f.out("gov"), "performance");
    assert_eq!(f.out("thp").trim(), "always [madvise] never");
    assert_eq!(f.pmqos_seen(), 2_000_000_000);
    // Profil cassé : même repli, avec la raison.
    fs::write(
        f.p("profiles/casse.toml"),
        "schema = 1\nid = \"casse\"\nname = \"x\"\ncouche = \"proton\"\nthp = \"jamais\"\n",
    )
    .unwrap();
    let out = f
        .cmd()
        .args(["launch", "--id", "casse", "--no-sched-hint", "--"])
        .args(f.game("true"))
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("refusé"), "{err}");
    assert_eq!(f.out("gov"), "performance");
}

#[test]
fn without_daemon_the_game_still_starts() {
    let f = Fake::new();
    let out = f
        .cmd()
        .args(["launch", "--id", "jeu-a", "--no-sched-hint", "--"])
        .args(f.game("exit 3"))
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(3), "{err}");
    assert!(err.contains("injoignable"), "{err}");
    assert_eq!(f.out("gov"), "performance");
    // Commande introuvable : 127.
    let out = f
        .cmd()
        .args(["launch", "--no-sched-hint", "--", "/nulle/part/jeu"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(127));
}

#[test]
fn killed_launcher_still_gets_the_base_back() {
    let f = Fake::new();
    let _d = Daemon::start(&f);
    let mut l = f
        .cmd()
        .args(["launch", "--id", "jeu-a", "--no-sched-hint", "--"])
        .args(f.game("exec sleep 30"))
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert!(wait_until(Duration::from_secs(10), || !f
        .out("pid")
        .is_empty()));
    assert_eq!(f.gov(0), "powersave");
    l.kill().unwrap(); // SIGKILL : aucun « end » envoyé
    l.wait().unwrap();
    assert!(
        wait_until(Duration::from_secs(5), || f.gov(0) == "performance"
            && f.thp() == "madvise"),
        "base non remise après la mort du launcher"
    );
    kill_pid(&f.out("pid"));
}

#[test]
fn second_game_on_top_then_first_comes_back() {
    let f = Fake::new();
    let _d = Daemon::start(&f);
    let mut a = f
        .cmd()
        .args([
            "launch",
            "--id",
            "jeu-a",
            "--no-sched-hint",
            "--",
            "sleep",
            "30",
        ])
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert!(wait_until(Duration::from_secs(10), || f.gov(0) == "powersave"));
    // Un jeu sans profil par-dessus : la base revient pendant qu'il tourne.
    let out = f
        .cmd()
        .args(["launch", "--id", "autre", "--no-sched-hint", "--"])
        .args(f.game("true"))
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_eq!(f.out("gov"), "performance");
    // Il se termine : le profil de A revient, A tourne toujours.
    assert_eq!(f.gov(0), "powersave");
    assert_eq!(f.thp(), "always");
    let st = f.cmd().arg("status").output().unwrap();
    let s = String::from_utf8_lossy(&st.stdout);
    assert!(s.contains("ACTIVE") && s.contains("jeu-a"), "{s}");
    // SIGTERM au launcher : transmis au jeu, puis base remise.
    // SAFETY: signal au launcher de test.
    unsafe {
        libc::kill(a.id() as i32, libc::SIGTERM);
    }
    let code = a.wait().unwrap();
    assert_eq!(code.code(), Some(143), "jeu tué par SIGTERM : 128 + 15");
    assert_eq!(f.gov(0), "performance");
    assert_eq!(f.thp(), "madvise");
}

#[test]
fn daemon_killed_mid_game_restores_the_base_when_it_restarts() {
    let f = Fake::new();
    let mut d = Daemon::start(&f);
    let l = f
        .cmd()
        .args(["launch", "--id", "jeu-a", "--no-sched-hint", "--"])
        .args(f.game("exec sleep 30"))
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert!(wait_until(Duration::from_secs(10), || f.gov(0) == "powersave"));
    assert!(f.p("run/applied.json").exists());
    d.signal(libc::SIGKILL);
    assert_eq!(f.gov(0), "powersave", "mort brutale : rien n'a été remis");
    let d2 = Daemon::start(&f);
    assert_eq!(f.gov(0), "performance");
    assert_eq!(f.gov(1), "performance");
    assert_eq!(f.thp(), "madvise");
    assert!(d2.log().contains("reprise"), "{}", d2.log());
    kill_pid(&f.out("pid"));
    let out = l.wait_with_output().unwrap();
    assert!(String::from_utf8_lossy(&out.stderr).contains("non confirmée"));
}

#[test]
fn sigterm_on_the_daemon_restores_and_removes_the_socket() {
    let f = Fake::new();
    let mut d = Daemon::start(&f);
    let mut l = f
        .cmd()
        .args(["launch", "--id", "jeu-a", "--no-sched-hint", "--"])
        .args(f.game("exec sleep 30"))
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert!(wait_until(Duration::from_secs(10), || f.gov(0) == "powersave"));
    let st = d.signal(libc::SIGTERM);
    assert!(st.success());
    assert_eq!(f.gov(0), "performance");
    assert_eq!(f.thp(), "madvise");
    assert!(!f.sock().exists());
    assert!(!f.p("run/applied.json").exists());
    kill_pid(&f.out("pid"));
    let _ = l.wait();
}

#[test]
fn prepare_switch_exit_codes() {
    let f = Fake::new();
    let none = f
        .cmd()
        .args(["prepare-switch", "--id", "jeu-switch"])
        .output()
        .unwrap();
    assert_eq!(none.status.code(), Some(3), "démon injoignable");
    let _d = Daemon::start(&f);
    let pending = f
        .cmd()
        .args(["prepare-switch", "--id", "jeu-switch"])
        .output()
        .unwrap();
    assert_eq!(
        pending.status.code(),
        Some(4),
        "{}",
        String::from_utf8_lossy(&pending.stderr)
    );
    let proton = f
        .cmd()
        .args(["prepare-switch", "--id", "jeu-a"])
        .output()
        .unwrap();
    assert_eq!(proton.status.code(), Some(1));
    let h = f.p("hooks/windows-security");
    fs::write(
        &h,
        format!(
            "#!/bin/sh\necho \"$RAGO_WINDOWS_SECURITY\" > {}\n",
            f.p("out/comm").display()
        ),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&h, fs::Permissions::from_mode(0o755)).unwrap();
    let ok = f
        .cmd()
        .args(["prepare-switch", "--id", "jeu-switch"])
        .output()
        .unwrap();
    assert_eq!(
        ok.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&ok.stderr)
    );
    assert_eq!(f.out("comm"), "perf");
    // Jeu inconnu : compat_max, le défaut sûr.
    let ok = f
        .cmd()
        .args(["prepare-switch", "--id", "inconnu"])
        .output()
        .unwrap();
    assert_eq!(ok.status.code(), Some(0));
    assert_eq!(f.out("comm"), "compat_max");
}

#[test]
fn show_list_and_validate_the_community_base() {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../profiles");
    let ok = Command::new(bin())
        .arg("validate")
        .arg(repo.join("community"))
        .arg(repo.join("schema/exemple-complet.toml"))
        .output()
        .unwrap();
    let s = String::from_utf8_lossy(&ok.stdout);
    assert!(ok.status.success(), "{s}");
    assert!(s.contains("0 refusé"), "{s}");
    let bad = Command::new(bin())
        .arg("validate")
        .arg(repo.join("tests/invalides"))
        .output()
        .unwrap();
    let s = String::from_utf8_lossy(&bad.stdout);
    assert_eq!(bad.status.code(), Some(1));
    let n = fs::read_dir(repo.join("tests/invalides")).unwrap().count();
    assert!(
        s.contains(&format!("0 profil(s) valide(s), {n} refusé(s)")),
        "{s}"
    );
    let show = Command::new(bin())
        .arg("--profiles-dir")
        .arg(repo.join("community"))
        .args(["show", "--steam-appid", "730", "--json"])
        .output()
        .unwrap();
    let v: serde_json::Value = serde_json::from_slice(&show.stdout).unwrap();
    assert_eq!(v["id"], "counter-strike-2");
    assert_eq!(v["cstates"], "shallow");
    let list = Command::new(bin())
        .arg("--profiles-dir")
        .arg(repo.join("community"))
        .arg("list")
        .output()
        .unwrap();
    let s = String::from_utf8_lossy(&list.stdout);
    for id in [
        "counter-strike-2",
        "cyberpunk-2077",
        "elden-ring",
        "fortnite",
        "valorant",
    ] {
        assert!(s.contains(id), "{s}");
    }
}

// --- bout en bout avec M0 ---------------------------------------------------------------

struct M0Server {
    sock: PathBuf,
    sink: Arc<Mutex<MemorySink>>,
    stop: Arc<AtomicBool>,
    th: Option<JoinHandle<()>>,
}

impl M0Server {
    fn start(dir: &Path) -> Self {
        let sock = dir.join("sched-hint.sock");
        let cpus = rago_common::affinity::get_thread(0).unwrap();
        let topo = Topology::manual(TopologyKind::Symmetric, cpus, CpuSet::new(), None).unwrap();
        let state = Arc::new(ServerState::new(
            topo,
            false,
            rago_common::DEFAULT_RENDER_COMMS
                .iter()
                .map(|s| s.to_string())
                .collect(),
            ServerConfig::default(),
        ));
        let sink = Arc::new(Mutex::new(MemorySink::default()));
        state.install_sink(Box::new(sink.clone())).unwrap();
        let (l, _) = server::bind(&sock, None).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let (st, sp) = (state, stop.clone());
        let th = Some(thread::spawn(move || server::serve(l, st, sp)));
        Self {
            sock,
            sink,
            stop,
            th,
        }
    }
}

impl Drop for M0Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.th.take() {
            let _ = t.join();
        }
    }
}

fn sched_hint_bin() -> PathBuf {
    if let Some(p) = std::env::var_os("RAGO_SCHED_HINT_BIN") {
        return PathBuf::from(p);
    }
    // target/<profil>/deps/cli-xxxx -> target/<profil>/rago-sched-hint
    let exe = std::env::current_exe().unwrap();
    let p = exe
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("rago-sched-hint");
    assert!(
        p.is_file(),
        "{} absent : lancer d'abord « cargo build -p rago-sched-hint » (ou daemons/rago-profiled/tests/run_tests.sh)",
        p.display()
    );
    p
}

#[test]
fn end_to_end_with_m0_the_game_is_tagged_with_its_render_threads() {
    let f = Fake::new();
    let _d = Daemon::start(&f);
    let m0 = M0Server::start(f.root());
    let hint = sched_hint_bin();
    let l = f
        .cmd()
        .env("RAGO_SCHED_HINT_SOCKET", &m0.sock)
        .arg("launch")
        .arg("--id")
        .arg("jeu-a")
        .arg("--sched-hint-bin")
        .arg(&hint)
        .arg("--")
        .args(f.game("exec sleep 30"))
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert!(wait_until(Duration::from_secs(10), || !f
        .out("pid")
        .is_empty()));
    let pid: u32 = f.out("pid").parse().unwrap();
    // rago-sched-hint a tagué SON pid puis fait execve() vers le jeu : même pid.
    assert!(
        wait_until(Duration::from_secs(5), || m0
            .sink
            .lock()
            .unwrap()
            .tgids
            .contains_key(&pid)),
        "jeu {pid} non tagué : {:?}",
        m0.sink.lock().unwrap().tgids
    );
    let comms = m0.sink.lock().unwrap().comms.clone();
    assert!(
        comms.iter().any(|c| c == "GameThread"),
        "motif du profil absent : {comms:?}"
    );
    assert!(
        comms.iter().any(|c| c == "dxvk-cs"),
        "motifs par défaut de M0 perdus : {comms:?}"
    );
    assert_eq!(f.gov(0), "powersave");
    kill_pid(&pid.to_string());
    let out = l.wait_with_output().unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("latency-critical"), "{err}");
    assert_eq!(f.gov(0), "performance");
}

#[test]
fn without_scx_rago_the_hint_tool_still_launches_the_game() {
    let f = Fake::new();
    let _d = Daemon::start(&f);
    let out = f
        .cmd()
        .env("RAGO_SCHED_HINT_SOCKET", f.p("run/absent.sock"))
        .arg("launch")
        .arg("--id")
        .arg("jeu-a")
        .arg("--sched-hint-bin")
        .arg(sched_hint_bin())
        .arg("--")
        .args(f.game("exit 5"))
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(5),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(f.out("gov"), "powersave");
    assert_eq!(f.gov(0), "performance");
}
