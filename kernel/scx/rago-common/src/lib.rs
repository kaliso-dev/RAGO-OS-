// SPDX-License-Identifier: GPL-2.0
//
// Rago OS — briques communes à scx_rago (l'ordonnanceur) et rago-sched-hint
// (l'outil appelé par le launcher).
//
// - `cpuset`   : ensembles de CPU au format noyau (« 0-7,16-23 »).
// - `topology` : détection Ryzen X3D / Intel hybride / symétrique via sysfs.
// - `proto`    : protocole texte du socket /run/rago/sched-hint.sock.
// - `procfs`   : propriétaire, threads et descendants d'un processus.
// - `server`   : serveur du socket (dans scx_rago), générique sur `HintSink`.
// - `client`   : client du socket (dans rago-sched-hint).
// - `affinity` : sched_setaffinity sur un processus et ses threads.

pub mod affinity;
pub mod client;
pub mod cpuset;
pub mod procfs;
pub mod proto;
pub mod server;
pub mod topology;

pub use cpuset::CpuSet;
pub use proto::{Hint, HintClass};
pub use topology::{Topology, TopologyKind};

/// Chemin par défaut du socket du canal launcher -> ordonnanceur.
pub const DEFAULT_SOCKET: &str = "/run/rago/sched-hint.sock";

/// Groupe Unix autorisé à parler au socket (le joueur doit en faire partie).
pub const DEFAULT_SOCKET_GROUP: &str = "rago";

/// Version de l'ABI des maps BPF (doit égaler RAGO_ABI_VERSION de rago_intf.h).
pub const ABI_VERSION: u32 = 1;

/// Version du protocole texte du socket.
pub const PROTO_VERSION: u32 = 1;

/// Longueur max d'un motif de nom de thread (TASK_COMM_LEN - 1).
pub const COMM_MAX: usize = 15;

/// Nombre max de motifs de nom de thread de rendu (RAGO_MAX_COMM_PATTERNS).
pub const MAX_COMM_PATTERNS: usize = 16;

/// Motifs par défaut de noms de threads de rendu / soumission GPU (préfixes
/// de task->comm, 15 caractères max). Ne s'appliquent qu'aux processus tagués
/// par le launcher. Enrichissables par jeu via les profils (M14).
pub const DEFAULT_RENDER_COMMS: &[&str] = &[
    "dxvk-cs",         // DXVK : thread de command stream D3D9/10/11
    "dxvk-submit",     // DXVK : soumission Vulkan
    "dxvk-queue",      // DXVK : présentation
    "vkd3d_queue",     // vkd3d-proton (D3D12) : file de soumission
    "RenderThread",    // Unreal Engine (« RenderThread 1 »)
    "RHIThread",       // Unreal Engine
    "RHISubmissionTh", // Unreal Engine 5 (« RHISubmissionThread » tronqué)
    "UnityGfxDeviceW", // Unity (« UnityGfxDeviceWorker » tronqué)
];
