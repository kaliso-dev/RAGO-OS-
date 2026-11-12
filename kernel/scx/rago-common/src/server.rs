// SPDX-License-Identifier: GPL-2.0
//
// Serveur du canal launcher -> ordonnanceur, exécuté dans scx_rago (root).
//
// Il reçoit les demandes de rago-sched-hint, vérifie que l'appelant possède
// bien le processus visé (SO_PEERCRED + /proc/<pid>/status), tient un
// registre des tags posés par le launcher et les écrit dans les maps BPF via
// un `HintSink`. Le registre survit à un rechargement de l'ordonnanceur :
// `install_sink()` réapplique tout ce qui est encore vivant.

use std::collections::BTreeMap;
use std::ffi::CString;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::procfs;
use crate::proto::{
    self, ErrCode, F_INHERITED, F_LAUNCHER, F_THREAD, Hint, HintClass, ListEntry, ProtoError,
    Request,
};
use crate::topology::Topology;
use crate::{ABI_VERSION, MAX_COMM_PATTERNS, PROTO_VERSION};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MapKind {
    /// rago_tgids : processus entiers.
    Tgid,
    /// rago_tids : threads explicites.
    Tid,
}

/// Destination des tags (les maps BPF dans scx_rago, une mémoire en test).
pub trait HintSink: Send {
    fn put(&mut self, map: MapKind, id: u32, hint: &Hint) -> io::Result<()>;
    /// Supprime une entrée ; une entrée absente n'est pas une erreur.
    fn delete(&mut self, map: MapKind, id: u32) -> io::Result<()>;
    fn list(&self, map: MapKind) -> io::Result<Vec<(u32, Hint)>>;
    fn set_comms(&mut self, patterns: &[String]) -> io::Result<()>;
}

/// Sink en mémoire (tests, et mode « sans BPF »).
#[derive(Default, Debug, Clone)]
pub struct MemorySink {
    pub tgids: BTreeMap<u32, Hint>,
    pub tids: BTreeMap<u32, Hint>,
    pub comms: Vec<String>,
}

impl HintSink for MemorySink {
    fn put(&mut self, map: MapKind, id: u32, hint: &Hint) -> io::Result<()> {
        match map {
            MapKind::Tgid => self.tgids.insert(id, *hint),
            MapKind::Tid => self.tids.insert(id, *hint),
        };
        Ok(())
    }

    fn delete(&mut self, map: MapKind, id: u32) -> io::Result<()> {
        match map {
            MapKind::Tgid => self.tgids.remove(&id),
            MapKind::Tid => self.tids.remove(&id),
        };
        Ok(())
    }

    fn list(&self, map: MapKind) -> io::Result<Vec<(u32, Hint)>> {
        Ok(match map {
            MapKind::Tgid => self.tgids.iter().map(|(k, v)| (*k, *v)).collect(),
            MapKind::Tid => self.tids.iter().map(|(k, v)| (*k, *v)).collect(),
        })
    }

    fn set_comms(&mut self, patterns: &[String]) -> io::Result<()> {
        self.comms = patterns.to_vec();
        Ok(())
    }
}

/// Sink partagé (pour inspecter un MemorySink depuis un test).
impl<T: HintSink> HintSink for Arc<Mutex<T>> {
    fn put(&mut self, map: MapKind, id: u32, hint: &Hint) -> io::Result<()> {
        self.lock().unwrap().put(map, id, hint)
    }
    fn delete(&mut self, map: MapKind, id: u32) -> io::Result<()> {
        self.lock().unwrap().delete(map, id)
    }
    fn list(&self, map: MapKind) -> io::Result<Vec<(u32, Hint)>> {
        self.lock().unwrap().list(map)
    }
    fn set_comms(&mut self, patterns: &[String]) -> io::Result<()> {
        self.lock().unwrap().set_comms(patterns)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PeerCred {
    pub pid: u32,
    pub uid: u32,
    pub gid: u32,
}

/// Identité du client d'un socket Unix (SO_PEERCRED).
pub fn peer_cred(stream: &UnixStream) -> io::Result<PeerCred> {
    let mut cred = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: cred/len décrivent un ucred valide ; fd ouvert.
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut cred as *mut _ as *mut libc::c_void,
            &mut len,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(PeerCred {
        pid: cred.pid as u32,
        uid: cred.uid,
        gid: cred.gid,
    })
}

#[derive(Clone, Debug)]
pub struct ServerConfig {
    pub proc_root: PathBuf,
    pub max_roots_per_uid: usize,
    pub max_threads_per_uid: usize,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            proc_root: PathBuf::from("/proc"),
            max_roots_per_uid: 32,
            max_threads_per_uid: 256,
        }
    }
}

struct Inner {
    sink: Option<Box<dyn HintSink>>,
    /// Racines posées par le launcher (TAG), clé = tgid.
    roots: BTreeMap<u32, Hint>,
    /// Threads posés explicitement (TAGTID), clé = tid.
    threads: BTreeMap<u32, Hint>,
    comms: Vec<String>,
    status: Vec<(String, String)>,
}

pub struct ServerState {
    cfg: ServerConfig,
    topology: Topology,
    confine: bool,
    inner: Mutex<Inner>,
}

/// Réponse : lignes de données puis ligne finale.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub data: Vec<String>,
    pub last: String,
}

impl Response {
    fn ok(kv: &[(&str, String)]) -> Self {
        let mut last = String::from("OK");
        for (k, v) in kv {
            last.push(' ');
            last.push_str(k);
            last.push('=');
            last.push_str(v);
        }
        Self {
            data: Vec::new(),
            last,
        }
    }
}

fn set_or_dash(s: &crate::CpuSet) -> String {
    if s.is_empty() {
        "-".into()
    } else {
        s.to_string()
    }
}

fn io_err(e: io::Error) -> ProtoError {
    ProtoError::new(ErrCode::Io, e.to_string())
}

impl ServerState {
    pub fn new(
        topology: Topology,
        confine: bool,
        comms: Vec<String>,
        cfg: ServerConfig,
    ) -> Self {
        let mut comms: Vec<String> = comms
            .into_iter()
            .filter(|c| proto::valid_comm_pattern(c))
            .collect();
        comms.dedup();
        comms.truncate(MAX_COMM_PATTERNS);
        Self {
            cfg,
            topology,
            confine,
            inner: Mutex::new(Inner {
                sink: None,
                roots: BTreeMap::new(),
                threads: BTreeMap::new(),
                comms,
                status: Vec::new(),
            }),
        }
    }

    pub fn topology(&self) -> &Topology {
        &self.topology
    }

    pub fn comms(&self) -> Vec<String> {
        self.inner.lock().unwrap().comms.clone()
    }

    /// Branche (ou rebranche après un rechargement) les maps BPF et y
    /// réapplique les motifs et tous les tags encore vivants.
    pub fn install_sink(&self, mut sink: Box<dyn HintSink>) -> io::Result<usize> {
        let mut inner = self.inner.lock().unwrap();
        self.prune_dead(&mut inner);
        sink.set_comms(&inner.comms)?;
        let mut n = 0;
        let roots: Vec<(u32, Hint)> = inner.roots.iter().map(|(k, v)| (*k, *v)).collect();
        for (pid, hint) in roots {
            n += self.apply_root(sink.as_mut(), pid, &hint)?;
        }
        for (tid, hint) in inner.threads.iter() {
            sink.put(MapKind::Tid, *tid, hint)?;
            n += 1;
        }
        inner.sink = Some(sink);
        Ok(n)
    }

    /// Débranche les maps (avant un rechargement de l'ordonnanceur).
    pub fn remove_sink(&self) -> Option<Box<dyn HintSink>> {
        self.inner.lock().unwrap().sink.take()
    }

    /// Compteurs exposés par STATUS (mis à jour par la boucle principale).
    pub fn set_status(&self, kv: Vec<(String, String)>) {
        self.inner.lock().unwrap().status = kv;
    }

    fn prune_dead(&self, inner: &mut Inner) {
        let root = &self.cfg.proc_root;
        let dead_roots: Vec<u32> = inner
            .roots
            .keys()
            .copied()
            .filter(|p| !procfs::exists(root, *p))
            .collect();
        let dead_threads: Vec<u32> = inner
            .threads
            .keys()
            .copied()
            .filter(|t| !procfs::exists(root, *t))
            .collect();
        for p in dead_roots {
            inner.roots.remove(&p);
            if let Some(s) = inner.sink.as_mut() {
                let _ = s.delete(MapKind::Tgid, p);
            }
        }
        for t in dead_threads {
            inner.threads.remove(&t);
            if let Some(s) = inner.sink.as_mut() {
                let _ = s.delete(MapKind::Tid, t);
            }
        }
    }

    /// Écrit la racine et ses descendants vivants (même propriétaire).
    fn apply_root(&self, sink: &mut dyn HintSink, pid: u32, hint: &Hint) -> io::Result<usize> {
        sink.put(MapKind::Tgid, pid, hint)?;
        let mut n = 1;
        let root = &self.cfg.proc_root;
        for d in procfs::descendants(root, pid).unwrap_or_default() {
            if procfs::real_uid(root, d).ok() != Some(hint.owner_uid) {
                continue;
            }
            let child = Hint {
                class: HintClass::Game,
                flags: (hint.flags & !F_LAUNCHER) | F_INHERITED,
                root_tgid: pid,
                owner_uid: hint.owner_uid,
                tagged_ns: hint.tagged_ns,
            };
            sink.put(MapKind::Tgid, d, &child)?;
            n += 1;
        }
        Ok(n)
    }

    fn authorize(&self, peer: &PeerCred, id: u32) -> Result<u32, ProtoError> {
        let root = &self.cfg.proc_root;
        if !procfs::exists(root, id) {
            return Err(ProtoError::new(ErrCode::Srch, format!("{id} n'existe pas")));
        }
        let owner = procfs::real_uid(root, id).map_err(|_| {
            ProtoError::new(ErrCode::Srch, format!("{id} a disparu"))
        })?;
        if peer.uid != 0 && owner != peer.uid {
            return Err(ProtoError::new(
                ErrCode::Perm,
                format!("{id} appartient à l'uid {owner}, pas à l'appelant (uid {})", peer.uid),
            ));
        }
        Ok(owner)
    }

    pub fn handle(&self, peer: &PeerCred, req: &Request) -> Result<Response, ProtoError> {
        let mut inner = self.inner.lock().unwrap();
        self.prune_dead(&mut inner);
        match req {
            Request::Hello { version } => {
                if *version != PROTO_VERSION {
                    return Err(ProtoError::new(
                        ErrCode::Version,
                        format!("protocole {version} non géré (serveur : {PROTO_VERSION})"),
                    ));
                }
                Ok(Response::ok(&[
                    ("proto", PROTO_VERSION.to_string()),
                    ("abi", ABI_VERSION.to_string()),
                    ("topo", self.topology.kind.to_string()),
                    ("game", set_or_dash(&self.topology.game)),
                    ("bg", set_or_dash(&self.topology.bg)),
                    ("confine", (self.confine as u8).to_string()),
                ]))
            }
            Request::Tag { pid } => {
                let owner = self.authorize(peer, *pid)?;
                let tgid = procfs::tgid_of(&self.cfg.proc_root, *pid).map_err(io_err)?;
                if tgid != *pid {
                    return Err(ProtoError::new(
                        ErrCode::Inval,
                        format!("{pid} est un thread du processus {tgid} : utiliser TAGTID"),
                    ));
                }
                if !inner.roots.contains_key(pid)
                    && inner.roots.values().filter(|h| h.owner_uid == owner).count()
                        >= self.cfg.max_roots_per_uid
                {
                    return Err(ProtoError::new(
                        ErrCode::Limit,
                        format!("trop de jeux tagués pour l'uid {owner}"),
                    ));
                }
                let hint = Hint {
                    class: HintClass::Game,
                    flags: F_LAUNCHER,
                    root_tgid: *pid,
                    owner_uid: owner,
                    tagged_ns: proto::monotonic_ns(),
                };
                inner.roots.insert(*pid, hint);
                let applied = match inner.sink.as_mut() {
                    Some(s) => self.apply_root(s.as_mut(), *pid, &hint).map_err(io_err)?,
                    None => 0,
                };
                Ok(Response::ok(&[
                    ("pid", pid.to_string()),
                    ("class", "game".into()),
                    ("tagged", applied.to_string()),
                    ("pending", ((applied == 0) as u8).to_string()),
                ]))
            }
            Request::TagThread { tid } => {
                let owner = self.authorize(peer, *tid)?;
                let tgid = procfs::tgid_of(&self.cfg.proc_root, *tid).map_err(io_err)?;
                if !inner.threads.contains_key(tid)
                    && inner.threads.values().filter(|h| h.owner_uid == owner).count()
                        >= self.cfg.max_threads_per_uid
                {
                    return Err(ProtoError::new(
                        ErrCode::Limit,
                        format!("trop de threads tagués pour l'uid {owner}"),
                    ));
                }
                let hint = Hint {
                    class: HintClass::Render,
                    flags: F_LAUNCHER | F_THREAD,
                    root_tgid: tgid,
                    owner_uid: owner,
                    tagged_ns: proto::monotonic_ns(),
                };
                inner.threads.insert(*tid, hint);
                let pending = match inner.sink.as_mut() {
                    Some(s) => {
                        s.put(MapKind::Tid, *tid, &hint).map_err(io_err)?;
                        0
                    }
                    None => 1,
                };
                Ok(Response::ok(&[
                    ("tid", tid.to_string()),
                    ("class", "render".into()),
                    ("pending", pending.to_string()),
                ]))
            }
            Request::Untag { pid } => {
                let pid = *pid;
                let mut owners: Vec<u32> = Vec::new();
                if let Some(h) = inner.roots.get(&pid) {
                    owners.push(h.owner_uid);
                }
                let mut tg: Vec<(u32, u32)> = Vec::new();
                let mut td: Vec<(u32, u32)> = Vec::new();
                if let Some(s) = inner.sink.as_ref() {
                    for (k, h) in s.list(MapKind::Tgid).map_err(io_err)? {
                        if k == pid || h.root_tgid == pid {
                            tg.push((k, h.owner_uid));
                        }
                    }
                    for (k, h) in s.list(MapKind::Tid).map_err(io_err)? {
                        if h.root_tgid == pid {
                            td.push((k, h.owner_uid));
                        }
                    }
                }
                for (k, h) in inner.threads.iter() {
                    if h.root_tgid == pid && !td.iter().any(|(t, _)| t == k) {
                        td.push((*k, h.owner_uid));
                    }
                }
                owners.extend(tg.iter().map(|(_, u)| *u));
                owners.extend(td.iter().map(|(_, u)| *u));
                if owners.is_empty() {
                    return Err(ProtoError::new(ErrCode::Srch, format!("{pid} n'est pas tagué")));
                }
                if peer.uid != 0 && owners.iter().any(|u| *u != peer.uid) {
                    return Err(ProtoError::new(
                        ErrCode::Perm,
                        format!("l'arbre de {pid} n'appartient pas à l'appelant"),
                    ));
                }
                inner.roots.remove(&pid);
                for (t, _) in &td {
                    inner.threads.remove(t);
                }
                if let Some(s) = inner.sink.as_mut() {
                    for (k, _) in &tg {
                        s.delete(MapKind::Tgid, *k).map_err(io_err)?;
                    }
                    for (k, _) in &td {
                        s.delete(MapKind::Tid, *k).map_err(io_err)?;
                    }
                }
                let removed = tg.len().max(1) + td.len();
                Ok(Response::ok(&[("removed", removed.to_string())]))
            }
            Request::Comm { pattern } => {
                if !inner.comms.iter().any(|c| c == pattern) {
                    if inner.comms.len() >= MAX_COMM_PATTERNS {
                        return Err(ProtoError::new(
                            ErrCode::Limit,
                            format!("{MAX_COMM_PATTERNS} motifs maximum"),
                        ));
                    }
                    inner.comms.push(pattern.clone());
                }
                let comms = inner.comms.clone();
                if let Some(s) = inner.sink.as_mut() {
                    s.set_comms(&comms).map_err(io_err)?;
                }
                Ok(Response::ok(&[("patterns", comms.len().to_string())]))
            }
            Request::List => {
                let (tg, td) = match inner.sink.as_ref() {
                    Some(s) => (
                        s.list(MapKind::Tgid).map_err(io_err)?,
                        s.list(MapKind::Tid).map_err(io_err)?,
                    ),
                    None => (
                        inner.roots.iter().map(|(k, v)| (*k, *v)).collect(),
                        inner.threads.iter().map(|(k, v)| (*k, *v)).collect(),
                    ),
                };
                let mut data = Vec::new();
                for (kind, entries) in [("tgid", tg), ("tid", td)] {
                    for (id, h) in entries {
                        data.push(
                            ListEntry {
                                kind: kind.into(),
                                id,
                                class: h.class,
                                flags: h.flags,
                                root: h.root_tgid,
                                uid: h.owner_uid,
                            }
                            .to_line(),
                        );
                    }
                }
                let mut r = Response::ok(&[("count", data.len().to_string())]);
                r.data = data;
                Ok(r)
            }
            Request::Status => {
                let mut kv: Vec<(&str, String)> = vec![
                    ("topo", self.topology.kind.to_string()),
                    ("game", set_or_dash(&self.topology.game)),
                    ("bg", set_or_dash(&self.topology.bg)),
                    ("confine", (self.confine as u8).to_string()),
                    ("roots", inner.roots.len().to_string()),
                    ("threads", inner.threads.len().to_string()),
                    ("patterns", inner.comms.len().to_string()),
                    (
                        "maps",
                        if inner.sink.is_some() { "ready" } else { "absent" }.into(),
                    ),
                ];
                let extra = inner.status.clone();
                for (k, v) in &extra {
                    kv.push((k.as_str(), v.clone()));
                }
                Ok(Response::ok(&kv))
            }
        }
    }
}

/// Crée le socket : dossier parent 0755, socket root:<groupe> 0660 (ou 0600
/// si le groupe n'existe pas). Renvoie aussi un avertissement éventuel.
pub fn bind(path: &Path, group: Option<&str>) -> io::Result<(UnixListener, Option<String>)> {
    if let Some(dir) = path.parent().filter(|d| !d.exists()) {
        fs::create_dir_all(dir)?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o755))?;
    }
    match fs::remove_file(path) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let listener = UnixListener::bind(path)?;
    let mut warning = None;
    let gid = group.and_then(lookup_gid);
    match (group, gid) {
        (Some(_), Some(gid)) => {
            let c = CString::new(path.as_os_str().as_encoded_bytes())
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
            // SAFETY: chemin C valide ; -1 = ne pas changer l'uid.
            if unsafe { libc::chown(c.as_ptr(), u32::MAX, gid) } != 0 {
                return Err(io::Error::last_os_error());
            }
            fs::set_permissions(path, fs::Permissions::from_mode(0o660))?;
        }
        (Some(g), None) => {
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
            warning = Some(format!(
                "groupe « {g} » introuvable : socket réservé à root (créez le groupe et ajoutez-y le joueur)"
            ));
        }
        (None, _) => {
            fs::set_permissions(path, fs::Permissions::from_mode(0o666))?;
        }
    }
    Ok((listener, warning))
}

/// GID d'un groupe (getgrnam_r).
pub fn lookup_gid(name: &str) -> Option<u32> {
    let c = CString::new(name).ok()?;
    let mut grp: libc::group = unsafe { std::mem::zeroed() };
    let mut buf = vec![0u8; 16384];
    let mut res: *mut libc::group = std::ptr::null_mut();
    // SAFETY: tampons valides et de la taille annoncée.
    let rc = unsafe {
        libc::getgrnam_r(
            c.as_ptr(),
            &mut grp,
            buf.as_mut_ptr() as *mut libc::c_char,
            buf.len(),
            &mut res,
        )
    };
    if rc != 0 || res.is_null() {
        return None;
    }
    Some(grp.gr_gid)
}

const MAX_REQUESTS_PER_CONN: usize = 64;

fn handle_conn(stream: UnixStream, state: &ServerState) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let peer = peer_cred(&stream)?;
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);
    for _ in 0..MAX_REQUESTS_PER_CONN {
        let mut line = String::new();
        let n = (&mut reader)
            .take(proto::MAX_LINE as u64 + 1)
            .read_line(&mut line)?;
        if n == 0 {
            return Ok(());
        }
        let resp = if !line.ends_with('\n') {
            Err(ProtoError::new(ErrCode::Inval, "ligne trop longue ou incomplète"))
        } else {
            Request::parse(line.trim_end()).and_then(|req| state.handle(&peer, &req))
        };
        let mut out = String::new();
        match resp {
            Ok(r) => {
                for d in r.data {
                    out.push_str(&d);
                    out.push('\n');
                }
                out.push_str(&r.last);
                out.push('\n');
            }
            Err(e) => {
                out.push_str(&e.to_line());
                out.push('\n');
            }
        }
        writer.write_all(out.as_bytes())?;
        if !line.ends_with('\n') {
            return Ok(());
        }
    }
    Ok(())
}

/// Boucle d'acceptation (à lancer dans un thread). S'arrête quand `shutdown`
/// passe à vrai (vérifié toutes les 100 ms).
pub fn serve(listener: UnixListener, state: Arc<ServerState>, shutdown: Arc<AtomicBool>) {
    let _ = listener.set_nonblocking(true);
    while !shutdown.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => {
                let _ = stream.set_nonblocking(false);
                if let Err(e) = handle_conn(stream, &state) {
                    eprintln!("rago-hint : connexion interrompue : {e}");
                }
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(e) => {
                eprintln!("rago-hint : accept() : {e}");
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cpuset::CpuSet;
    use crate::topology::TopologyKind;

    fn fake_proc(dir: &Path, pid: u32, tgid: u32, ppid: u32, uid: u32) {
        let p = dir.join(pid.to_string());
        fs::create_dir_all(p.join("task")).unwrap();
        fs::create_dir_all(p.join(format!("task/{pid}"))).unwrap();
        fs::write(
            p.join("status"),
            format!("Tgid:\t{tgid}\nPPid:\t{ppid}\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n"),
        )
        .unwrap();
        fs::write(
            p.join("stat"),
            format!("{pid} (g) S {ppid} 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n"),
        )
        .unwrap();
    }

    fn state(proc_root: &Path) -> ServerState {
        let topo = Topology::manual(
            TopologyKind::X3d,
            CpuSet::parse("0-15").unwrap(),
            CpuSet::parse("0-7").unwrap(),
            None,
        )
        .unwrap();
        ServerState::new(
            topo,
            true,
            vec!["dxvk-cs".into(), "RenderThread".into()],
            ServerConfig {
                proc_root: proc_root.to_path_buf(),
                max_roots_per_uid: 2,
                max_threads_per_uid: 2,
            },
        )
    }

    const USER: PeerCred = PeerCred {
        pid: 1,
        uid: 1000,
        gid: 1000,
    };
    const OTHER: PeerCred = PeerCred {
        pid: 1,
        uid: 1001,
        gid: 1001,
    };
    const ROOT: PeerCred = PeerCred {
        pid: 1,
        uid: 0,
        gid: 0,
    };

    #[test]
    fn hello_reports_topology() {
        let d = tempfile::tempdir().unwrap();
        let s = state(d.path());
        let r = s.handle(&USER, &Request::Hello { version: 1 }).unwrap();
        assert_eq!(r.last, "OK proto=1 abi=1 topo=x3d game=0-7 bg=8-15 confine=1");
        assert_eq!(
            s.handle(&USER, &Request::Hello { version: 9 }).unwrap_err().code,
            ErrCode::Version
        );
    }

    #[test]
    fn tag_tree_and_untag() {
        let d = tempfile::tempdir().unwrap();
        fake_proc(d.path(), 100, 100, 1, 1000); // jeu
        fake_proc(d.path(), 101, 100, 1, 1000); // thread du jeu
        fake_proc(d.path(), 200, 200, 100, 1000); // enfant du jeu
        let s = state(d.path());
        let sink = Arc::new(Mutex::new(MemorySink::default()));
        s.install_sink(Box::new(sink.clone())).unwrap();
        assert_eq!(sink.lock().unwrap().comms, vec!["dxvk-cs", "RenderThread"]);

        let r = s.handle(&USER, &Request::Tag { pid: 100 }).unwrap();
        assert!(r.last.contains("tagged=2"), "{}", r.last);
        {
            let m = sink.lock().unwrap();
            let root = m.tgids[&100];
            assert_eq!(root.class, HintClass::Game);
            assert_eq!(root.flags, F_LAUNCHER);
            assert_eq!(root.owner_uid, 1000);
            let child = m.tgids[&200];
            assert_eq!(child.flags, F_INHERITED);
            assert_eq!(child.root_tgid, 100);
        }

        // Un thread ne peut pas être une racine.
        assert_eq!(
            s.handle(&USER, &Request::Tag { pid: 101 }).unwrap_err().code,
            ErrCode::Inval
        );
        s.handle(&USER, &Request::TagThread { tid: 101 }).unwrap();
        assert_eq!(sink.lock().unwrap().tids[&101].class, HintClass::Render);
        assert_eq!(sink.lock().unwrap().tids[&101].root_tgid, 100);

        let list = s.handle(&USER, &Request::List).unwrap();
        assert_eq!(list.data.len(), 3);
        assert_eq!(list.last, "OK count=3");

        // Un autre utilisateur ne peut pas retirer l'arbre.
        assert_eq!(
            s.handle(&OTHER, &Request::Untag { pid: 100 }).unwrap_err().code,
            ErrCode::Perm
        );
        let r = s.handle(&USER, &Request::Untag { pid: 100 }).unwrap();
        assert_eq!(r.last, "OK removed=3");
        let m = sink.lock().unwrap();
        assert!(m.tgids.is_empty() && m.tids.is_empty());
    }

    #[test]
    fn ownership_is_enforced() {
        let d = tempfile::tempdir().unwrap();
        fake_proc(d.path(), 100, 100, 1, 1000);
        fake_proc(d.path(), 300, 300, 1, 0);
        let s = state(d.path());
        assert_eq!(
            s.handle(&OTHER, &Request::Tag { pid: 100 }).unwrap_err().code,
            ErrCode::Perm
        );
        assert_eq!(
            s.handle(&USER, &Request::Tag { pid: 300 }).unwrap_err().code,
            ErrCode::Perm
        );
        assert!(s.handle(&ROOT, &Request::Tag { pid: 100 }).is_ok());
        assert_eq!(
            s.handle(&USER, &Request::Tag { pid: 999 }).unwrap_err().code,
            ErrCode::Srch
        );
    }

    #[test]
    fn limits_and_pending_then_reinstall() {
        let d = tempfile::tempdir().unwrap();
        for p in [100, 110, 120] {
            fake_proc(d.path(), p, p, 1, 1000);
        }
        let s = state(d.path());
        // Pas encore de maps : le tag est mémorisé (pending=1).
        let r = s.handle(&USER, &Request::Tag { pid: 100 }).unwrap();
        assert!(r.last.ends_with("pending=1"), "{}", r.last);
        s.handle(&USER, &Request::Tag { pid: 110 }).unwrap();
        assert_eq!(
            s.handle(&USER, &Request::Tag { pid: 120 }).unwrap_err().code,
            ErrCode::Limit
        );
        // Re-taguer une racine existante ne compte pas dans la limite.
        assert!(s.handle(&USER, &Request::Tag { pid: 100 }).is_ok());

        // Branchement des maps : tout est réappliqué.
        let sink = Arc::new(Mutex::new(MemorySink::default()));
        assert_eq!(s.install_sink(Box::new(sink.clone())).unwrap(), 2);
        assert!(sink.lock().unwrap().tgids.contains_key(&110));

        // Le processus 110 meurt : il est purgé à la requête suivante.
        fs::remove_dir_all(d.path().join("110")).unwrap();
        let st = s.handle(&USER, &Request::Status).unwrap();
        assert!(st.last.contains("roots=1"), "{}", st.last);
        assert!(!sink.lock().unwrap().tgids.contains_key(&110));
    }

    #[test]
    fn comm_patterns() {
        let d = tempfile::tempdir().unwrap();
        let s = state(d.path());
        let sink = Arc::new(Mutex::new(MemorySink::default()));
        s.install_sink(Box::new(sink.clone())).unwrap();
        s.handle(
            &USER,
            &Request::Comm {
                pattern: "MyRender".into(),
            },
        )
        .unwrap();
        // Doublon ignoré.
        let r = s
            .handle(
                &USER,
                &Request::Comm {
                    pattern: "dxvk-cs".into(),
                },
            )
            .unwrap();
        assert_eq!(r.last, "OK patterns=3");
        assert_eq!(sink.lock().unwrap().comms.len(), 3);
        for i in 0..13 {
            s.handle(
                &USER,
                &Request::Comm {
                    pattern: format!("p{i}"),
                },
            )
            .unwrap();
        }
        assert_eq!(
            s.handle(
                &USER,
                &Request::Comm {
                    pattern: "onemore".into()
                }
            )
            .unwrap_err()
            .code,
            ErrCode::Limit
        );
    }
}
