// SPDX-License-Identifier: GPL-2.0
//
// Le démon : tourne en root (service rago-profiled), écoute
// /run/rago-profiled/profiled.sock (root:rago 0660, le même groupe que le
// canal M0) et applique les profils.
//
// Session = une connexion. `rago-profiled launch` (le launcher, en
// utilisateur) ouvre une session, le démon applique le profil du jeu, et le
// profil reste tant que la connexion est ouverte. À la fin du jeu, ou si le
// launcher meurt (le noyau ferme le socket), la session se termine.
//
// Plusieurs jeux en même temps : pile de sessions. Seule la dernière ouverte
// est appliquée ; quand elle se termine, celle d'en dessous revient ; quand la
// pile est vide, le réglage de base (M1) revient exactement.

use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use rago_common::server::{lookup_gid, peer_cred};

use crate::hooks::{HOOK_WINDOWS_SECURITY, HookOutcome, Hooks};
use crate::linux::{Applier, PMQOS_DEFAULT_US, System};
use crate::profile::{Couche, Effective, Query, Store};
use crate::proto::{
    Action, ActionStatus as S, MAX_LINE, PROTO_VERSION, Request, Response, SessionInfo,
};

pub const MAX_SESSIONS: usize = 32;
pub const MAX_SESSIONS_PER_UID: usize = 8;
const MAX_CONNECTIONS: usize = 64;
pub const STATE_FILE: &str = "applied.json";

#[derive(Clone, Debug)]
pub struct Config {
    pub socket: PathBuf,
    /// Groupe du socket (None : socket réservé au propriétaire du démon).
    pub group: Option<String>,
    pub state_dir: PathBuf,
    pub profile_dirs: Vec<PathBuf>,
    pub hooks_dir: PathBuf,
    pub root: PathBuf,
    pub pmqos_dev: PathBuf,
    pub hook_timeout: Duration,
}

struct Session {
    id: u64,
    uid: u32,
    pid: u32,
    label: String,
    eff: Effective,
    started: Instant,
}

struct Inner {
    store: Store,
    applier: Applier,
    stack: Vec<Session>,
    next: u64,
}

pub struct Daemon {
    inner: Mutex<Inner>,
    hooks: Hooks,
}

pub fn log(msg: &str) {
    eprintln!("rago-profiled : {msg}");
}

fn log_actions(prefix: &str, actions: &[Action]) {
    for a in actions {
        log(&format!("{prefix}{}", a.to_string().trim_end()));
    }
}

impl Daemon {
    /// Crée le démon et remet la base si une instance précédente est morte
    /// en laissant un profil appliqué.
    pub fn new(cfg: &Config) -> (Self, Vec<Action>) {
        let sys = System::new(cfg.root.clone(), cfg.pmqos_dev.clone());
        let hooks = Hooks::new(cfg.hooks_dir.clone(), cfg.hook_timeout);
        let mut applier = Applier::new(sys, hooks.clone(), cfg.state_dir.join(STATE_FILE));
        let recovered = applier.recover();
        let store = Store::load(&cfg.profile_dirs);
        (
            Self {
                inner: Mutex::new(Inner {
                    store,
                    applier,
                    stack: Vec::new(),
                    next: 1,
                }),
                hooks,
            },
            recovered,
        )
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // Un thread qui panique ne doit pas bloquer la remise de la base.
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Charge les profils ; renvoie (profils valides, erreurs).
    pub fn reload(&self) -> (usize, usize) {
        let mut g = self.lock();
        let dirs = g.store.dirs().to_vec();
        g.store = Store::load(&dirs);
        (g.store.entries().count(), g.store.errors.len())
    }

    pub fn store_report(&self) -> Vec<String> {
        let g = self.lock();
        let mut v: Vec<String> = g
            .store
            .errors
            .iter()
            .map(|e| format!("profil refusé : {} : {}", e.path.display(), e.message))
            .collect();
        v.extend(g.store.notes.iter().cloned());
        v
    }

    /// Ouvre une session et applique le profil du jeu.
    pub fn begin(&self, uid: u32, pid: u32, query: &Query, label: &str) -> Response {
        let mut g = self.lock();
        if g.stack.len() >= MAX_SESSIONS {
            return Response::err(format!("trop de sessions ouvertes ({MAX_SESSIONS} max)"));
        }
        if g.stack.iter().filter(|s| s.uid == uid).count() >= MAX_SESSIONS_PER_UID {
            return Response::err(format!(
                "trop de sessions pour l'uid {uid} ({MAX_SESSIONS_PER_UID} max)"
            ));
        }
        if g.store.refresh() {
            log(&format!(
                "profils rechargés : {} valides, {} refusés",
                g.store.entries().count(),
                g.store.errors.len()
            ));
        }
        let eff = g.store.resolve(query);
        let mut actions = Vec::new();
        if let Some(r) = &eff.fallback {
            actions.push(Action::new("profil", S::Info, r.clone()));
        }
        if eff.couche == Couche::Switch {
            actions.push(Action::new(
                "couche",
                S::Info,
                "profil de couche switch : ce jeu se lance par le Fast OS Switch (M6) ; \
                 ici aucun réglage Linux n'est surchargé",
            ));
        }
        for w in &eff.warnings {
            actions.push(Action::new("profil", S::Info, w.clone()));
        }
        actions.extend(g.applier.apply(&eff));
        let id = g.next;
        g.next += 1;
        let label = if label.is_empty() { eff.id.clone() } else { label.to_string() };
        log(&format!(
            "session {id} (uid {uid}, pid {pid}) « {label} » : profil {} ({})",
            eff.id,
            eff.matched_by.as_deref().unwrap_or("repli")
        ));
        log_actions(&format!("session {id} : "), &actions);
        g.stack.push(Session {
            id,
            uid,
            pid,
            label,
            eff: eff.clone(),
            started: Instant::now(),
        });
        Response {
            ok: true,
            session: Some(id),
            profile: Some(eff),
            actions,
            ..Default::default()
        }
    }

    /// Termine une session (idempotent).
    pub fn end(&self, id: u64) -> Response {
        let mut g = self.lock();
        let Some(pos) = g.stack.iter().position(|s| s.id == id) else {
            return Response {
                ok: true,
                ..Default::default()
            };
        };
        let was_top = pos + 1 == g.stack.len();
        let s = g.stack.remove(pos);
        let mut actions = Vec::new();
        if g.stack.is_empty() {
            actions.extend(g.applier.restore());
        } else if was_top {
            let top = g.stack.last().expect("non vide");
            let (label, eff) = (top.label.clone(), top.eff.clone());
            actions.push(Action::new(
                "profil",
                S::Info,
                format!("le jeu « {label} » tourne encore : son profil {} revient", eff.id),
            ));
            actions.extend(g.applier.apply(&eff));
        } else {
            let top = g.stack.last().expect("non vide");
            actions.push(Action::new(
                "profil",
                S::Info,
                format!("le profil de « {} » reste appliqué", top.label),
            ));
        }
        log(&format!(
            "session {id} « {} » terminée après {} s",
            s.label,
            s.started.elapsed().as_secs()
        ));
        log_actions(&format!("session {id} : "), &actions);
        Response {
            ok: true,
            session: Some(id),
            actions,
            ..Default::default()
        }
    }

    pub fn status(&self) -> Response {
        let g = self.lock();
        let n = g.stack.len();
        let sessions = g
            .stack
            .iter()
            .enumerate()
            .map(|(i, s)| SessionInfo {
                session: s.id,
                uid: s.uid,
                pid: s.pid,
                label: s.label.clone(),
                profile: s.eff.id.clone(),
                age_s: s.started.elapsed().as_secs(),
                active: i + 1 == n,
            })
            .collect();
        let sys = g.applier.system();
        let pols = sys.policies();
        let mut govs: Vec<String> = pols
            .iter()
            .filter_map(|p| sys.read_policy(p).map(|s| s.governor))
            .collect();
        govs.dedup();
        let mut actions = vec![
            Action::new(
                "cpu_governor",
                S::Info,
                if pols.is_empty() {
                    "cpufreq absent".to_string()
                } else {
                    format!("{} ({} politique(s))", govs.join(", "), pols.len())
                },
            ),
            Action::new("thp", S::Info, sys.thp().unwrap_or_else(|| "absent".into())),
        ];
        let hold = match g.applier.cstates_hold() {
            Some((m, us)) => format!("demande du jeu : {m} ({us} µs)"),
            None => "aucune demande du jeu".into(),
        };
        let base = sys
            .m1_cstates()
            .map(|m| format!("base M1 : {m}"))
            .unwrap_or_else(|| "M1 non installé".into());
        let eff = match sys.pmqos_effective() {
            Some(v) if v >= PMQOS_DEFAULT_US => "aucune limite".to_string(),
            Some(v) => format!("{v} µs"),
            None => "illisible".into(),
        };
        actions.push(Action::new("cstates", S::Info, format!("{hold} ; {base} ; latence effective {eff}")));
        actions.push(Action::new(
            "mitigations",
            S::Info,
            format!("noyau : {}", sys.kernel_mitigations()),
        ));
        for (name, module) in [("gpu-clocks", "M9"), (HOOK_WINDOWS_SECURITY, "M5/M6")] {
            let st = if self.hooks.is_present(name) {
                "présent".to_string()
            } else {
                format!("absent ({module} pas encore installé)")
            };
            actions.push(Action::new(&format!("hook {name}"), S::Info, st));
        }
        Response {
            ok: true,
            sessions,
            actions,
            base: g.applier.saved().and_then(|s| serde_json::to_value(s).ok()),
            ..Default::default()
        }
    }

    /// Couche switch : écrit le profil de sécurité Windows du jeu via le
    /// hook de M5/M6, juste avant le switch. Aucun réglage Linux.
    pub fn prepare_switch(&self, query: &Query) -> Response {
        let eff = {
            let mut g = self.lock();
            g.store.refresh();
            let mut q = query.clone();
            q.couche.get_or_insert(Couche::Switch);
            g.store.resolve(&q)
        };
        if eff.couche != Couche::Switch {
            return Response::err(format!(
                "le profil « {} » est de couche proton : ce jeu se lance sous Linux, pas de switch",
                eff.id
            ));
        }
        let mut actions = Vec::new();
        if let Some(r) = &eff.fallback {
            actions.push(Action::new("profil", S::Info, r.clone()));
        }
        let value = eff.windows_security.to_string();
        let json = serde_json::to_string(&eff).unwrap_or_else(|_| "{}".into());
        let env = [
            ("RAGO_PROFILE_ID", eff.id.clone()),
            ("RAGO_WINDOWS_SECURITY", value.clone()),
        ];
        const K: &str = "windows_security";
        actions.push(match self.hooks.run(HOOK_WINDOWS_SECURITY, &["set"], &env, &json) {
            HookOutcome::Ok(m) => Action::new(K, S::Applied, format!("{value} transmis au micro-Windows {m}").trim().to_string()),
            HookOutcome::Absent => Action::new(
                K,
                S::Pending,
                format!(
                    "{value} demandé ; M5/M6 (micro-Windows, RAGO-COMM) pas encore installés : hook {} absent",
                    self.hooks.path(HOOK_WINDOWS_SECURITY).display()
                ),
            ),
            HookOutcome::Refused(m) => Action::new(K, S::Error, format!("hook refusé : {m}")),
            HookOutcome::Failed(m) => Action::new(K, S::Error, format!("hook en échec : {m}")),
        });
        log(&format!("switch : profil {} -> windows_security {value}", eff.id));
        log_actions("switch : ", &actions);
        Response {
            ok: true,
            profile: Some(eff),
            actions,
            ..Default::default()
        }
    }

    /// Arrêt du démon : toutes les sessions se terminent, la base revient.
    pub fn shutdown(&self) -> Vec<Action> {
        let mut g = self.lock();
        g.stack.clear();
        g.applier.restore()
    }
}

// --- socket -------------------------------------------------------------------------------

/// Termine la session quoi qu'il arrive (erreur, client tué, panique).
struct SessionGuard<'a> {
    d: &'a Daemon,
    id: u64,
}

impl Drop for SessionGuard<'_> {
    fn drop(&mut self) {
        self.d.end(self.id);
    }
}

enum Read1 {
    Eof,
    Bad(String),
    Req(Request),
}

fn read_request(r: &mut BufReader<UnixStream>) -> io::Result<Read1> {
    let mut line = String::new();
    let n = r.by_ref().take(MAX_LINE as u64 + 1).read_line(&mut line)?;
    if n == 0 {
        return Ok(Read1::Eof);
    }
    if !line.ends_with('\n') {
        return Ok(if n > MAX_LINE {
            Read1::Bad("ligne trop longue".into())
        } else {
            Read1::Eof
        });
    }
    Ok(match serde_json::from_str::<Request>(line.trim_end()) {
        Ok(req) => Read1::Req(req),
        Err(e) => Read1::Bad(format!("requête invalide : {e}")),
    })
}

fn send(w: &mut UnixStream, resp: &Response) -> io::Result<()> {
    let mut s = serde_json::to_string(resp).map_err(io::Error::other)?;
    s.push('\n');
    w.write_all(s.as_bytes())
}

fn handle_conn(stream: UnixStream, d: &Daemon) -> io::Result<()> {
    let peer = peer_cred(&stream)?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let mut w = stream.try_clone()?;
    let mut r = BufReader::new(stream);
    let req = match read_request(&mut r)? {
        Read1::Eof => return Ok(()),
        Read1::Bad(e) => return send(&mut w, &Response::err(e)),
        Read1::Req(req) => req,
    };
    match req {
        Request::Apply { v, query, label } => {
            if v != PROTO_VERSION {
                return send(
                    &mut w,
                    &Response::err(format!("protocole {v} non pris en charge (démon : {PROTO_VERSION})")),
                );
            }
            let resp = d.begin(peer.uid, peer.pid, &query, &label);
            let Some(id) = resp.session else {
                return send(&mut w, &resp);
            };
            let guard = SessionGuard { d, id };
            send(&mut w, &resp)?;
            // Le jeu tourne : on attend « end » ou la fermeture du socket,
            // aussi longtemps qu'il le faut.
            r.get_ref().set_read_timeout(None)?;
            loop {
                match read_request(&mut r) {
                    Ok(Read1::Req(Request::End)) => {
                        std::mem::forget(guard);
                        let resp = d.end(id);
                        let _ = send(&mut w, &resp);
                        return Ok(());
                    }
                    Ok(Read1::Req(Request::Status)) => send(&mut w, &d.status())?,
                    Ok(Read1::Req(_)) => send(&mut w, &Response::err("session ouverte : seul « end » est accepté"))?,
                    Ok(Read1::Bad(e)) => send(&mut w, &Response::err(e))?,
                    Ok(Read1::Eof) | Err(_) => {
                        log(&format!("session {id} : le launcher est parti sans « end »"));
                        return Ok(()); // guard -> end()
                    }
                }
            }
        }
        Request::End => send(&mut w, &Response::err("aucune session sur cette connexion")),
        Request::Status => send(&mut w, &d.status()),
        Request::PrepareSwitch { v, query } => {
            if v != PROTO_VERSION {
                return send(
                    &mut w,
                    &Response::err(format!("protocole {v} non pris en charge (démon : {PROTO_VERSION})")),
                );
            }
            send(&mut w, &d.prepare_switch(&query))
        }
    }
}

/// Crée le socket. Refuse de démarrer si un autre démon répond déjà.
fn bind(path: &Path, group: Option<&str>) -> io::Result<(UnixListener, Option<String>)> {
    if let Some(dir) = path.parent().filter(|d| !d.exists()) {
        fs::create_dir_all(dir)?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o755))?;
    }
    if path.exists() {
        if UnixStream::connect(path).is_ok() {
            return Err(io::Error::new(
                io::ErrorKind::AddrInUse,
                format!("{} : un autre rago-profiled tourne déjà", path.display()),
            ));
        }
        fs::remove_file(path)?;
    }
    let listener = UnixListener::bind(path)?;
    let mut warning = None;
    match group.map(|g| (g, lookup_gid(g))) {
        Some((_, Some(gid))) => {
            let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes())
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
            // SAFETY: chemin C valide ; uid -1 = inchangé.
            if unsafe { libc::chown(c.as_ptr(), u32::MAX, gid) } != 0 {
                return Err(io::Error::last_os_error());
            }
            fs::set_permissions(path, fs::Permissions::from_mode(0o660))?;
        }
        Some((g, None)) => {
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
            warning = Some(format!(
                "groupe « {g} » introuvable : socket réservé à root (le groupe est créé par M0, \
                 kernel/build_rago_kernel.sh scx-install --user <joueur>)"
            ));
        }
        None => fs::set_permissions(path, fs::Permissions::from_mode(0o600))?,
    }
    Ok((listener, warning))
}

static SHUTDOWN: AtomicBool = AtomicBool::new(false);
static RELOAD: AtomicBool = AtomicBool::new(false);

extern "C" fn on_stop(_: libc::c_int) {
    SHUTDOWN.store(true, Ordering::SeqCst);
}

extern "C" fn on_hup(_: libc::c_int) {
    RELOAD.store(true, Ordering::SeqCst);
}

fn install_signals() {
    // SAFETY: les gestionnaires ne font qu'écrire un AtomicBool.
    unsafe {
        libc::signal(libc::SIGTERM, on_stop as extern "C" fn(libc::c_int) as libc::sighandler_t);
        libc::signal(libc::SIGINT, on_stop as extern "C" fn(libc::c_int) as libc::sighandler_t);
        libc::signal(libc::SIGHUP, on_hup as extern "C" fn(libc::c_int) as libc::sighandler_t);
    }
}

/// `rago-profiled daemon`.
pub fn run(cfg: Config) -> ExitCode {
    install_signals();
    let (d, recovered) = Daemon::new(&cfg);
    log_actions("reprise : ", &recovered);
    let d = Arc::new(d);
    let (n, errs) = {
        let g = d.lock();
        (g.store.entries().count(), g.store.errors.len())
    };
    log(&format!(
        "{n} profil(s) chargé(s), {errs} refusé(s), depuis {}",
        cfg.profile_dirs
            .iter()
            .map(|p| p.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    ));
    for line in d.store_report() {
        log(&line);
    }
    let (listener, warning) = match bind(&cfg.socket, cfg.group.as_deref()) {
        Ok(x) => x,
        Err(e) => {
            log(&format!("socket {} impossible : {e}", cfg.socket.display()));
            return ExitCode::FAILURE;
        }
    };
    if let Some(w) = warning {
        log(&format!("attention : {w}"));
    }
    if let Err(e) = listener.set_nonblocking(true) {
        log(&format!("socket : {e}"));
        return ExitCode::FAILURE;
    }
    log(&format!("prêt sur {}", cfg.socket.display()));
    let conns = Arc::new(AtomicUsize::new(0));
    while !SHUTDOWN.load(Ordering::SeqCst) {
        if RELOAD.swap(false, Ordering::SeqCst) {
            let (n, e) = d.reload();
            log(&format!("SIGHUP : {n} profil(s) valides, {e} refusé(s)"));
            for line in d.store_report() {
                log(&line);
            }
        }
        match listener.accept() {
            Ok((stream, _)) => {
                if conns.load(Ordering::SeqCst) >= MAX_CONNECTIONS {
                    log("trop de connexions : refusée");
                    continue;
                }
                let _ = stream.set_nonblocking(false);
                conns.fetch_add(1, Ordering::SeqCst);
                let (d, conns) = (Arc::clone(&d), Arc::clone(&conns));
                thread::spawn(move || {
                    if let Err(e) = handle_conn(stream, &d) {
                        log(&format!("connexion : {e}"));
                    }
                    conns.fetch_sub(1, Ordering::SeqCst);
                });
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(100));
            }
            Err(e) => {
                log(&format!("accept() : {e}"));
                thread::sleep(Duration::from_millis(100));
            }
        }
    }
    log("arrêt : remise du réglage de base");
    log_actions("arrêt : ", &d.shutdown());
    let _ = fs::remove_file(&cfg.socket);
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::linux::fake::FakeRoot;
    use crate::profile::{CStates, GpuMode, WindowsSecurity};

    fn config(f: &FakeRoot, profiles: &Path) -> Config {
        Config {
            socket: f.root().join("run/profiled.sock"),
            group: None,
            state_dir: f.root().join("run"),
            profile_dirs: vec![profiles.to_path_buf()],
            hooks_dir: f.root().join("hooks"),
            root: f.root().to_path_buf(),
            pmqos_dev: f.root().join("dev/cpu_dma_latency"),
            hook_timeout: Duration::from_secs(5),
        }
    }

    fn profiles() -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        fs::write(
            d.path().join("jeu-a.toml"),
            "schema = 1\nid = \"jeu-a\"\nname = \"A\"\ncouche = \"proton\"\ncpu_governor = \"powersave\"\nthp = \"always\"\ncstates = \"shallow\"\n[match]\nsteam_appid = [10]\n",
        )
        .unwrap();
        fs::write(
            d.path().join("jeu-b.json"),
            r#"{"schema":1,"id":"jeu-b","name":"B","couche":"proton","cstates":"poll","gpu_clocks":{"mode":"max"}}"#,
        )
        .unwrap();
        fs::write(
            d.path().join("anti-triche.toml"),
            "schema = 1\nid = \"anti-triche\"\nname = \"AC\"\ncouche = \"switch\"\nwindows_security = \"perf\"\n",
        )
        .unwrap();
        d
    }

    fn q(id: &str) -> Query {
        Query {
            id: Some(id.into()),
            ..Default::default()
        }
    }

    #[test]
    fn stack_of_sessions_top_wins_then_base_returns() {
        let f = FakeRoot::new(&["performance", "performance"], "performance powersave");
        let p = profiles();
        let (d, rec) = Daemon::new(&config(&f, p.path()));
        assert!(rec.is_empty());
        let a = d.begin(1000, 1, &q("jeu-a"), "A");
        assert!(a.ok);
        assert_eq!(f.gov(0), "powersave");
        assert_eq!(f.thp(), "always");
        let b = d.begin(1000, 2, &q("jeu-b"), "B");
        let pb = b.profile.unwrap();
        assert_eq!(pb.cstates, Some(CStates::Poll));
        assert_eq!(pb.gpu_clocks.mode, GpuMode::Max);
        // B ne fixe ni gouverneur ni THP : la base revient pendant B.
        assert_eq!(f.gov(0), "performance");
        assert_eq!(f.thp(), "madvise");
        assert!(b.actions.iter().any(|x| x.knob == "gpu_clocks" && x.status == S::Pending));
        let st = d.status();
        assert_eq!(st.sessions.len(), 2);
        assert!(st.sessions[1].active && !st.sessions[0].active);
        // Fin de B : A revient.
        d.end(b.session.unwrap());
        assert_eq!(f.gov(1), "powersave");
        assert_eq!(f.thp(), "always");
        // Fin de A : base exacte, fichier d'état supprimé.
        let r = d.end(a.session.unwrap());
        assert!(r.actions.iter().all(|x| x.status == S::Restored), "{:?}", r.actions);
        assert_eq!(f.gov(0), "performance");
        assert_eq!(f.thp(), "madvise");
        assert!(!f.root().join("run").join(STATE_FILE).exists());
        // Fin en double : sans effet.
        assert!(d.end(a.session.unwrap()).actions.is_empty());
    }

    #[test]
    fn ending_a_lower_session_keeps_the_top_profile() {
        let f = FakeRoot::new(&["performance"], "performance powersave");
        let p = profiles();
        let (d, _) = Daemon::new(&config(&f, p.path()));
        let a = d.begin(1000, 1, &q("jeu-a"), "A");
        let c = d.begin(1000, 3, &q("inconnu"), "C");
        assert!(c.profile.as_ref().unwrap().is_fallback());
        assert_eq!(f.gov(0), "performance", "le repli ne garde rien de A");
        let r = d.end(a.session.unwrap());
        assert!(r.actions[0].detail.contains("reste appliqué"));
        assert_eq!(f.gov(0), "performance");
        d.end(c.session.unwrap());
        assert_eq!(f.gov(0), "performance");
    }

    #[test]
    fn limits_and_switch_profile_on_linux() {
        let f = FakeRoot::new(&["performance"], "performance powersave");
        let p = profiles();
        let (d, _) = Daemon::new(&config(&f, p.path()));
        let mut ids = Vec::new();
        for i in 0..MAX_SESSIONS_PER_UID {
            let r = d.begin(1000, i as u32, &q("anti-triche"), "x");
            assert!(r.ok);
            assert!(r.actions.iter().any(|x| x.knob == "couche"));
            ids.push(r.session.unwrap());
        }
        let r = d.begin(1000, 99, &q("jeu-a"), "x");
        assert!(!r.ok);
        assert!(d.begin(1001, 99, &q("jeu-a"), "x").ok);
        assert!(!d.shutdown().is_empty());
        assert_eq!(f.gov(0), "performance");
    }

    #[test]
    fn prepare_switch_pending_then_hook() {
        let f = FakeRoot::new(&["performance"], "performance");
        let p = profiles();
        let (d, _) = Daemon::new(&config(&f, p.path()));
        let r = d.prepare_switch(&q("anti-triche"));
        assert!(r.ok);
        let a = r.actions.last().unwrap();
        assert_eq!(a.status, S::Pending, "{a:?}");
        assert!(a.detail.contains("M5/M6"));
        // Profil proton : pas de switch.
        assert!(!d.prepare_switch(&q("jeu-a")).ok);
        // Jeu inconnu : repli, compat_max.
        let r = d.prepare_switch(&q("inconnu"));
        assert!(r.ok);
        assert_eq!(r.profile.unwrap().windows_security, WindowsSecurity::CompatMax);
        // Le hook de M5/M6 reçoit la valeur.
        let out = f.root().join("comm.txt");
        let h = f.root().join("hooks/windows-security");
        fs::write(
            &h,
            format!("#!/bin/sh\necho \"$1 $RAGO_PROFILE_ID $RAGO_WINDOWS_SECURITY\" > {}\n", out.display()),
        )
        .unwrap();
        fs::set_permissions(&h, fs::Permissions::from_mode(0o755)).unwrap();
        let r = d.prepare_switch(&q("anti-triche"));
        assert_eq!(r.actions.last().unwrap().status, S::Applied);
        assert_eq!(fs::read_to_string(&out).unwrap(), "set anti-triche perf\n");
    }

    #[test]
    fn new_daemon_recovers_after_crash() {
        let f = FakeRoot::new(&["performance"], "performance powersave");
        let p = profiles();
        let cfg = config(&f, p.path());
        let (d, _) = Daemon::new(&cfg);
        d.begin(1000, 1, &q("jeu-a"), "A");
        assert_eq!(f.gov(0), "powersave");
        std::mem::forget(d);
        let (_d2, rec) = Daemon::new(&cfg);
        assert!(!rec.is_empty());
        assert_eq!(f.gov(0), "performance");
        assert_eq!(f.thp(), "madvise");
    }
}
