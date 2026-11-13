// SPDX-License-Identifier: GPL-2.0
//
// Tests d'intégration de rago-sched-hint : le vrai binaire contre un vrai
// serveur (rago-common) branché sur un sink en mémoire à la place des maps BPF.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use rago_common::proto::{F_LAUNCHER, HintClass};
use rago_common::server::{self, MemorySink, ServerConfig, ServerState};
use rago_common::topology::fake::FakeSysfs;
use rago_common::{CpuSet, Topology, TopologyKind};

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_rago-sched-hint"))
}

struct TestServer {
    sock: PathBuf,
    sink: Arc<Mutex<MemorySink>>,
    stop: Arc<AtomicBool>,
    th: Option<JoinHandle<()>>,
}

impl TestServer {
    fn start(dir: &Path, topo: Topology, confine: bool) -> Self {
        let sock = dir.join("sched-hint.sock");
        let state = Arc::new(ServerState::new(
            topo,
            confine,
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
        let th = Some(std::thread::spawn(move || server::serve(l, st, sp)));
        Self {
            sock,
            sink,
            stop,
            th,
        }
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.th.take() {
            let _ = t.join();
        }
    }
}

fn cpus_allowed(status: &str) -> String {
    status
        .lines()
        .find_map(|l| l.strip_prefix("Cpus_allowed_list:"))
        .unwrap()
        .trim()
        .to_string()
}

/// CPU réellement disponibles pour le test (le conteneur peut en avoir peu).
fn my_cpus() -> CpuSet {
    rago_common::affinity::get_thread(0).unwrap()
}

#[test]
fn topology_command_detects_fake_x3d() {
    let d = tempfile::tempdir().unwrap();
    let f = FakeSysfs::new(d.path(), "0-15").unwrap();
    f.l3("0-7", "96M").unwrap();
    f.l3("8-15", "32M").unwrap();
    let out = bin()
        .args(["--sysfs-root", d.path().to_str().unwrap(), "topology"])
        .output()
        .unwrap();
    assert!(out.status.success());
    let s = String::from_utf8_lossy(&out.stdout);
    assert!(s.contains("topo=x3d"), "{s}");
    assert!(s.contains("game=0-7"), "{s}");
    assert!(s.contains("bg=8-15"), "{s}");
    assert!(s.contains("confine=1"), "{s}");
}

#[test]
fn run_tags_itself_then_execs_with_same_pid() {
    let d = tempfile::tempdir().unwrap();
    let cpus = my_cpus();
    let topo = Topology::manual(TopologyKind::Symmetric, cpus, CpuSet::new(), None).unwrap();
    let srv = TestServer::start(d.path(), topo, false);
    // Le jeu factice affiche son PID : ce doit être le PID tagué.
    let out = bin()
        .env("RAGO_SCHED_HINT_SOCKET", &srv.sock)
        .args(["run", "--", "sh", "-c", "echo $$"])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let pid: u32 = String::from_utf8_lossy(&out.stdout).trim().parse().unwrap();
    // Le processus est mort : le tag a été posé (le serveur le purgera ensuite).
    let m = srv.sink.lock().unwrap();
    let h = m.tgids.get(&pid).expect("le jeu doit avoir été tagué avant exec");
    assert_eq!(h.class, HintClass::Game);
    assert_eq!(h.flags, F_LAUNCHER);
    assert_eq!(h.root_tgid, pid);
    assert!(m.comms.iter().any(|c| c == "dxvk-cs"));
}

#[test]
fn run_confines_on_x3d_from_server_topology() {
    let cpus = my_cpus();
    if cpus.len() < 2 {
        eprintln!("test ignoré : un seul CPU disponible");
        return;
    }
    let d = tempfile::tempdir().unwrap();
    let half: CpuSet = cpus.iter().take(cpus.len() / 2).collect();
    let topo = Topology::manual(TopologyKind::X3d, cpus.clone(), half.clone(), None).unwrap();
    let srv = TestServer::start(d.path(), topo, true);
    let out = bin()
        .env("RAGO_SCHED_HINT_SOCKET", &srv.sock)
        .args(["run", "--render-comm", "MyRender", "--", "cat", "/proc/self/status"])
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_eq!(cpus_allowed(&String::from_utf8_lossy(&out.stdout)), half.to_string());
    assert!(srv.sink.lock().unwrap().comms.iter().any(|c| c == "MyRender"));

    // --confine off : affinité inchangée.
    let out = bin()
        .env("RAGO_SCHED_HINT_SOCKET", &srv.sock)
        .args(["run", "--confine", "off", "--", "cat", "/proc/self/status"])
        .output()
        .unwrap();
    assert_eq!(cpus_allowed(&String::from_utf8_lossy(&out.stdout)), cpus.to_string());
}

#[test]
fn run_without_scheduler_still_launches_and_confines_locally() {
    let cpus = my_cpus();
    if cpus.len() < 2 {
        eprintln!("test ignoré : un seul CPU disponible");
        return;
    }
    // Faux X3D local : la première moitié des CPU porte le « cache 3D ».
    let v: Vec<u32> = cpus.iter().collect();
    let (a, b) = v.split_at(v.len() / 2);
    let a: CpuSet = a.iter().copied().collect();
    let b: CpuSet = b.iter().copied().collect();
    let d = tempfile::tempdir().unwrap();
    let f = FakeSysfs::new(d.path(), &cpus.to_string()).unwrap();
    f.l3(&a.to_string(), "96M").unwrap();
    f.l3(&b.to_string(), "32M").unwrap();
    let out = bin()
        .env("RAGO_SCHED_HINT_SOCKET", d.path().join("absent.sock"))
        .args([
            "--sysfs-root",
            d.path().to_str().unwrap(),
            "run",
            "--",
            "cat",
            "/proc/self/status",
        ])
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("filet EEVDF"));
    assert_eq!(cpus_allowed(&String::from_utf8_lossy(&out.stdout)), a.to_string());
}

#[test]
fn run_reports_exec_failure() {
    let d = tempfile::tempdir().unwrap();
    let out = bin()
        .env("RAGO_SCHED_HINT_SOCKET", d.path().join("absent.sock"))
        .args(["-q", "run", "--confine", "off", "--", "/nonexistent/game"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(127));
}

#[test]
fn tag_list_untag_existing_process() {
    let d = tempfile::tempdir().unwrap();
    let topo = Topology::manual(TopologyKind::Symmetric, my_cpus(), CpuSet::new(), None).unwrap();
    let srv = TestServer::start(d.path(), topo, false);
    let mut game = Command::new("sleep").arg("30").spawn().unwrap();
    let pid = game.id();
    let sock = srv.sock.to_str().unwrap().to_string();

    let out = bin()
        .args(["--socket", &sock, "tag", "--pid", &pid.to_string()])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));

    let out = bin().args(["--socket", &sock, "list"]).output().unwrap();
    let s = String::from_utf8_lossy(&out.stdout);
    assert!(s.contains(&format!("HINT tgid {pid} game 1 {pid}")), "{s}");

    // Thread de rendu explicite (ici le seul thread de sleep).
    let out = bin()
        .args(["--socket", &sock, "tag-thread", "--tid", &pid.to_string()])
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_eq!(srv.sink.lock().unwrap().tids[&pid].class, HintClass::Render);

    let out = bin().args(["--socket", &sock, "status"]).output().unwrap();
    let s = String::from_utf8_lossy(&out.stdout);
    assert!(s.contains("scx_rago=running") && s.contains("roots=1"), "{s}");

    let out = bin()
        .args(["--socket", &sock, "untag", "--pid", &pid.to_string()])
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(srv.sink.lock().unwrap().tgids.is_empty());
    assert!(srv.sink.lock().unwrap().tids.is_empty());

    // PID 1 n'appartient pas à un utilisateur ordinaire ; en root, refus « thread ».
    let _ = game.kill();
    let _ = game.wait();
}

#[test]
fn commands_exit_3_without_scheduler() {
    let d = tempfile::tempdir().unwrap();
    let sock = d.path().join("absent.sock");
    for args in [vec!["list"], vec!["untag", "--pid", "1"], vec!["status"]] {
        let out = bin()
            .arg("--socket")
            .arg(&sock)
            .args(&args)
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(3), "{args:?}");
    }
}
