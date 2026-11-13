// SPDX-License-Identifier: GPL-2.0
//
// Rago OS — partie espace utilisateur des ajouts Rago à scx_lavd :
//   - options --rago-* et détection de topologie (rago-common) ;
//   - remplissage du rodata BPF (masques jeu / fond) avant le chargement ;
//   - `BpfSink` : écrit les tags du launcher dans les maps rago_tgids,
//     rago_tids et rago_comms ;
//   - serveur du socket /run/rago/sched-hint.sock (thread dédié).

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use anyhow::{Context, Result, bail};
use libbpf_rs::{MapCore, MapFlags, MapHandle};
use rago_common::proto::{HINT_SIZE, Hint};
use rago_common::server::{self, HintSink, MapKind, ServerConfig, ServerState};
use rago_common::{CpuSet, Topology, TopologyKind};
use tracing::{info, warn};

use crate::bpf_intf::{
    LAVD_CPU_ID_MAX, rago_consts_RAGO_ABI_VERSION as RAGO_ABI_VERSION,
    rago_consts_RAGO_COMM_LEN as RAGO_COMM_LEN,
    rago_consts_RAGO_MAX_COMM_PATTERNS as RAGO_MAX_COMM_PATTERNS, rago_hint,
};
use crate::bpf_skel::{BpfSkel, OpenBpfSkel};

// L'ABI BPF (rago_intf.h) et la brique commune doivent rester alignées.
const _: () = assert!(std::mem::size_of::<rago_hint>() == HINT_SIZE);
const _: () = assert!(RAGO_ABI_VERSION == rago_common::ABI_VERSION);
const _: () = assert!(RAGO_MAX_COMM_PATTERNS as usize == rago_common::MAX_COMM_PATTERNS);
const _: () = assert!(RAGO_COMM_LEN as usize == rago_common::COMM_MAX + 1);

/// Options Rago (ajoutées à la ligne de commande de scx_lavd).
#[derive(Debug, Clone, clap::Args)]
pub struct RagoOpts {
    /// [Rago] Topologie : auto (détection sysfs), x3d, hybrid ou symmetric.
    #[clap(long = "rago-topo", default_value = "auto")]
    pub topo: String,

    /// [Rago] Masque jeu imposé (ex. « 0-7,16-23 »), avec --rago-topo x3d|hybrid.
    #[clap(long = "rago-game-cpus")]
    pub game_cpus: Option<String>,

    /// [Rago] Masque fond imposé (défaut : CPU en ligne hors masque jeu).
    #[clap(long = "rago-bg-cpus")]
    pub bg_cpus: Option<String>,

    /// [Rago] Désactive le routage CPU (garde le boost de criticité des tags).
    #[clap(long = "rago-no-routing", action = clap::ArgAction::SetTrue)]
    pub no_routing: bool,

    /// [Rago] Ne pousse pas les tâches de fond vers le masque fond pendant un jeu.
    #[clap(long = "rago-no-bg-steer", action = clap::ArgAction::SetTrue)]
    pub no_bg_steer: bool,

    /// [Rago] Ne demande pas aux clients de confiner le jeu (affinité X3D).
    #[clap(long = "rago-no-confine", action = clap::ArgAction::SetTrue)]
    pub no_confine: bool,

    /// [Rago] Socket du canal launcher -> ordonnanceur.
    #[clap(long = "rago-socket", default_value = rago_common::DEFAULT_SOCKET)]
    pub socket: PathBuf,

    /// [Rago] Groupe autorisé sur le socket (le joueur doit en faire partie).
    #[clap(long = "rago-socket-group", default_value = rago_common::DEFAULT_SOCKET_GROUP)]
    pub socket_group: String,

    /// [Rago] Préfixe de nom de thread de rendu en plus des motifs par défaut (répétable).
    #[clap(long = "rago-render-comm")]
    pub render_comms: Vec<String>,

    /// [Rago] Racine du sysfs pour la détection (tests).
    #[clap(long = "rago-sysfs-root", default_value = "/", hide = true)]
    pub sysfs_root: PathBuf,
}

/// Topologie effective (détectée ou imposée).
pub fn resolve_topology(o: &RagoOpts) -> Result<Topology> {
    let detected = Topology::detect(&o.sysfs_root).context("détection de la topologie CPU")?;
    if o.topo == "auto" {
        if o.game_cpus.is_some() {
            bail!("--rago-game-cpus exige --rago-topo x3d|hybrid");
        }
        return Ok(detected);
    }
    let kind = TopologyKind::parse(&o.topo)
        .with_context(|| format!("--rago-topo inconnu : {}", o.topo))?;
    if kind == TopologyKind::Symmetric {
        return Topology::manual(kind, detected.online, CpuSet::new(), None)
            .map_err(anyhow::Error::msg);
    }
    let game = match &o.game_cpus {
        Some(s) => CpuSet::parse(s)?,
        None if detected.kind == kind => detected.game.clone(),
        None => bail!("--rago-topo {kind} sans détection concordante : préciser --rago-game-cpus"),
    };
    let bg = match &o.bg_cpus {
        Some(s) => Some(CpuSet::parse(s)?),
        None => None,
    };
    Topology::manual(kind, detected.online, game, bg).map_err(anyhow::Error::msg)
}

/// Écrit la configuration Rago dans le rodata, avant le chargement.
pub fn init_rodata(skel: &mut OpenBpfSkel, o: &RagoOpts, topo: &Topology) {
    let words = LAVD_CPU_ID_MAX as usize / 64;
    let game = topo.game.to_words(words);
    let bg = topo.bg.to_words(words);
    let rodata = skel.maps.rodata_data.as_mut().unwrap();
    rodata.rago_topo_kind = topo.kind.as_bpf();
    rodata.rago_routing = (!o.no_routing) as u8;
    rodata.rago_bg_steer = (!o.no_bg_steer) as u8;
    rodata.rago_game_cpus.copy_from_slice(&game);
    rodata.rago_bg_cpus.copy_from_slice(&bg);
}

/// Motifs de threads de rendu : défauts + options.
pub fn render_comms(o: &RagoOpts) -> Vec<String> {
    let mut v: Vec<String> = rago_common::DEFAULT_RENDER_COMMS
        .iter()
        .map(|s| s.to_string())
        .collect();
    for c in &o.render_comms {
        if !rago_common::proto::valid_comm_pattern(c) {
            warn!("motif de rendu ignoré (1 à 15 caractères ASCII) : {c}");
        } else if !v.contains(c) {
            v.push(c.clone());
        }
    }
    v.truncate(RAGO_MAX_COMM_PATTERNS as usize);
    v
}

/// Les maps BPF de scx_rago, vues comme destination des tags.
pub struct BpfSink {
    tgids: MapHandle,
    tids: MapHandle,
    comms: MapHandle,
}

impl BpfSink {
    pub fn new(skel: &BpfSkel) -> Result<Self> {
        Ok(Self {
            tgids: MapHandle::try_from(&skel.maps.rago_tgids)?,
            tids: MapHandle::try_from(&skel.maps.rago_tids)?,
            comms: MapHandle::try_from(&skel.maps.rago_comms)?,
        })
    }

    fn map(&self, m: MapKind) -> &MapHandle {
        match m {
            MapKind::Tgid => &self.tgids,
            MapKind::Tid => &self.tids,
        }
    }
}

fn to_io(e: libbpf_rs::Error) -> io::Error {
    io::Error::other(e.to_string())
}

impl HintSink for BpfSink {
    fn put(&mut self, m: MapKind, id: u32, hint: &Hint) -> io::Result<()> {
        self.map(m)
            .update(&id.to_ne_bytes(), &hint.encode(), MapFlags::ANY)
            .map_err(to_io)
    }

    fn delete(&mut self, m: MapKind, id: u32) -> io::Result<()> {
        match self.map(m).delete(&id.to_ne_bytes()) {
            Ok(()) => Ok(()),
            // ENOENT : déjà supprimé (par exemple par rago_exit_task()).
            Err(e) if e.kind() == libbpf_rs::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(to_io(e)),
        }
    }

    fn list(&self, m: MapKind) -> io::Result<Vec<(u32, Hint)>> {
        let map = self.map(m);
        let mut out = Vec::new();
        for k in map.keys() {
            let Ok(kb): Result<[u8; 4], _> = k.as_slice().try_into() else {
                continue;
            };
            let v = map.lookup(&k, MapFlags::ANY).map_err(to_io)?;
            if let Some(h) = v.filter(|v| v.len() == HINT_SIZE).and_then(|v| Hint::decode(&v)) {
                out.push((u32::from_ne_bytes(kb), h));
            }
        }
        out.sort_by_key(|(k, _)| *k);
        Ok(out)
    }

    fn set_comms(&mut self, patterns: &[String]) -> io::Result<()> {
        for i in 0..RAGO_MAX_COMM_PATTERNS {
            let mut v = [0u8; RAGO_COMM_LEN as usize];
            if let Some(p) = patterns.get(i as usize) {
                let b = p.as_bytes();
                let n = b.len().min(RAGO_COMM_LEN as usize - 1);
                v[..n].copy_from_slice(&b[..n]);
            }
            self.comms
                .update(&i.to_ne_bytes(), &v, MapFlags::ANY)
                .map_err(to_io)?;
        }
        Ok(())
    }
}

/// Crée l'état partagé et démarre le thread du socket.
pub fn start_server(
    o: &RagoOpts,
    topo: Topology,
    shutdown: Arc<AtomicBool>,
) -> Result<Arc<ServerState>> {
    let confine = topo.confine_by_default() && !o.no_confine;
    info!("Rago : {}", topo.detail);
    let state = Arc::new(ServerState::new(
        topo,
        confine,
        render_comms(o),
        ServerConfig::default(),
    ));
    let (listener, warning) = server::bind(&o.socket, Some(&o.socket_group))
        .with_context(|| format!("création du socket {}", o.socket.display()))?;
    if let Some(w) = warning {
        warn!("Rago : {w}");
    }
    info!("Rago : canal launcher prêt sur {}", o.socket.display());
    let st = state.clone();
    std::thread::Builder::new()
        .name("rago-hint".into())
        .spawn(move || server::serve(listener, st, shutdown))?;
    Ok(state)
}

/// Branche les maps du nouvel ordonnanceur et y réapplique les tags.
pub fn install_maps(state: &ServerState, skel: &BpfSkel) -> Result<()> {
    let n = state
        .install_sink(Box::new(BpfSink::new(skel)?))
        .context("écriture des tags Rago dans les maps BPF")?;
    if n > 0 {
        info!("Rago : {n} tag(s) réappliqué(s) après rechargement");
    }
    Ok(())
}

/// Compteurs BPF pour STATUS.
pub fn publish_stats(state: &ServerState, skel: &BpfSkel) {
    let s = &skel.maps.bss_data.as_ref().unwrap().rago_stats;
    state.set_status(vec![
        ("abi".into(), RAGO_ABI_VERSION.to_string()),
        ("game_tasks".into(), s.nr_game_tasks.to_string()),
        ("render_tasks".into(), s.nr_render_tasks.to_string()),
        ("inherited".into(), s.nr_inherited.to_string()),
        ("steal_blocked".into(), s.nr_steal_blocked.to_string()),
        ("tagged_lookups".into(), s.nr_tagged_lookups.to_string()),
    ]);
}

/// Supprime le socket à l'arrêt.
pub fn cleanup_socket(path: &Path) {
    let _ = std::fs::remove_file(path);
}
