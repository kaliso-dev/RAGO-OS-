// SPDX-License-Identifier: GPL-2.0
//
// rago-sched-hint — l'API « hint » du launcher Rago vers l'ordonnanceur scx_rago.
//
// Le launcher (M11) lance un jeu ainsi :
//
//     rago-sched-hint run -- <commande du jeu>
//
// rago-sched-hint tague alors SON PROPRE processus comme racine du jeu auprès
// de scx_rago (socket /run/rago/sched-hint.sock), applique si besoin
// l'affinité stricte (CCD à cache 3D sur Ryzen X3D), puis fait execve() vers
// le jeu : le PID ne change pas, le jeu est donc tagué AVANT sa première
// instruction, et tous ses enfants héritent du tag (côté BPF, au fork).
//
// Si scx_rago ne tourne pas (filet EEVDF+BORE), le jeu est lancé quand même :
// seule l'affinité X3D, appliquée par le noyau, reste active.

use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use clap::{Parser, Subcommand, ValueEnum};
use rago_common::client::{Client, ClientError, HelloInfo};
use rago_common::{affinity, CpuSet, Topology, TopologyKind, DEFAULT_SOCKET};

/// Code de sortie quand scx_rago est injoignable (tag non posé).
const EXIT_NO_SCHED: u8 = 3;

#[derive(Parser, Debug)]
#[command(
    name = "rago-sched-hint",
    version,
    about = "Tague l'arbre de processus d'un jeu comme latency-critical pour scx_rago (Rago OS)"
)]
struct Cli {
    /// Socket du canal launcher -> scx_rago.
    #[arg(long, env = "RAGO_SCHED_HINT_SOCKET", default_value = DEFAULT_SOCKET, global = true)]
    socket: PathBuf,

    /// Racine du sysfs pour la détection locale de topologie (tests).
    #[arg(long, default_value = "/", global = true, hide = true)]
    sysfs_root: PathBuf,

    /// N'affiche que les erreurs.
    #[arg(short, long, global = true)]
    quiet: bool,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, ValueEnum)]
enum Confine {
    /// X3D : oui ; Intel hybride et symétrique : non.
    Auto,
    /// Toujours confiner le jeu à ses cœurs (masque jeu).
    On,
    /// Ne jamais toucher à l'affinité.
    Off,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Tague ce processus comme jeu puis exécute la commande (même PID).
    Run {
        #[arg(long, value_enum, default_value_t = Confine::Auto)]
        confine: Confine,
        /// Préfixe de nom de thread de rendu à ajouter (répétable).
        #[arg(long = "render-comm", value_name = "MOTIF")]
        render_comms: Vec<String>,
        /// Commande du jeu et ses arguments (après --).
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        command: Vec<String>,
    },
    /// Tague un processus déjà lancé (et ses enfants) comme jeu.
    Tag {
        #[arg(long)]
        pid: u32,
        #[arg(long, value_enum, default_value_t = Confine::Auto)]
        confine: Confine,
    },
    /// Tague un thread précis comme thread de rendu.
    TagThread {
        #[arg(long)]
        tid: u32,
    },
    /// Retire le tag d'un jeu et de tout son arbre.
    Untag {
        #[arg(long)]
        pid: u32,
    },
    /// Liste les tags présents dans les maps BPF.
    List,
    /// État de sched_ext, de scx_rago et du routage.
    Status,
    /// Affiche la topologie détectée localement (X3D / hybride / symétrique).
    Topology,
}

struct Ctx {
    socket: PathBuf,
    sysfs_root: PathBuf,
    quiet: bool,
}

impl Ctx {
    fn info(&self, msg: &str) {
        if !self.quiet {
            eprintln!("rago-sched-hint : {msg}");
        }
    }

    fn warn(&self, msg: &str) {
        eprintln!("rago-sched-hint : attention : {msg}");
    }

    fn connect(&self) -> Result<(Client, HelloInfo), ClientError> {
        let mut c = Client::connect(&self.socket)?;
        let h = c.hello()?;
        if h.abi != rago_common::ABI_VERSION {
            return Err(ClientError::Protocol(format!(
                "ABI scx_rago {} ≠ outil {}",
                h.abi,
                rago_common::ABI_VERSION
            )));
        }
        Ok((c, h))
    }

    /// Topologie locale (si scx_rago est absent).
    fn local_topology(&self) -> Topology {
        match Topology::detect(&self.sysfs_root) {
            Ok(t) => t,
            Err(e) => {
                self.warn(&format!("détection de topologie impossible ({e}) : pas de routage"));
                Topology {
                    kind: TopologyKind::Symmetric,
                    online: CpuSet::new(),
                    game: CpuSet::new(),
                    bg: CpuSet::new(),
                    detail: String::new(),
                }
            }
        }
    }
}

/// Masque d'affinité à appliquer, ou None.
fn confine_set(mode: Confine, default_on: bool, game: &CpuSet) -> Option<CpuSet> {
    let on = match mode {
        Confine::On => true,
        Confine::Off => false,
        Confine::Auto => default_on,
    };
    if on && !game.is_empty() {
        Some(game.clone())
    } else {
        None
    }
}

fn cmd_run(ctx: &Ctx, confine: Confine, render_comms: &[String], command: &[String]) -> ExitCode {
    let me = std::process::id();
    let (game, confine_default) = match ctx.connect() {
        Ok((mut c, h)) => {
            for p in render_comms {
                if let Err(e) = c.comm(p) {
                    ctx.warn(&format!("motif de rendu « {p} » refusé : {e}"));
                }
            }
            match c.tag(me) {
                Ok(r) => ctx.info(&format!("jeu tagué latency-critical ({r}) — topologie {}", h.topo)),
                Err(e) => ctx.warn(&format!("tag refusé : {e}")),
            }
            (h.game, h.confine)
        }
        Err(e) => {
            ctx.warn(&format!("{e} — jeu lancé sans hint (filet EEVDF)"));
            let t = ctx.local_topology();
            let d = t.confine_by_default();
            (t.game, d)
        }
    };

    if let Some(set) = confine_set(confine, confine_default, &game) {
        // Rester dans l'affinité déjà imposée (cpuset, taskset...).
        let allowed = affinity::get_thread(0).unwrap_or_default();
        let target = if allowed.is_empty() {
            set
        } else {
            set.intersection(&allowed)
        };
        if target.is_empty() {
            ctx.warn("masque jeu hors de l'affinité courante : affinité inchangée");
        } else if let Err(e) = affinity::set_thread(0, &target) {
            ctx.warn(&format!("affinité {target} impossible : {e}"));
        } else {
            ctx.info(&format!("jeu confiné aux CPU {target}"));
        }
    }

    let err = Command::new(&command[0]).args(&command[1..]).exec();
    eprintln!("rago-sched-hint : impossible d'exécuter « {} » : {err}", command[0]);
    ExitCode::from(127)
}

fn cmd_tag(ctx: &Ctx, pid: u32, confine: Confine) -> ExitCode {
    let (res, game, confine_default) = match ctx.connect() {
        Ok((mut c, h)) => (Some(c.tag(pid)), h.game, h.confine),
        Err(e) => {
            ctx.warn(&e.to_string());
            let t = ctx.local_topology();
            let d = t.confine_by_default();
            (None, t.game, d)
        }
    };
    if let Some(set) = confine_set(confine, confine_default, &game) {
        match affinity::set_tree(Path::new("/proc"), pid, &set) {
            Ok(n) => ctx.info(&format!("{n} threads confinés aux CPU {set}")),
            Err(e) => ctx.warn(&format!("affinité impossible : {e}")),
        }
    }
    match res {
        Some(Ok(r)) => {
            println!("{r}");
            ExitCode::SUCCESS
        }
        Some(Err(e)) => {
            eprintln!("rago-sched-hint : {e}");
            ExitCode::FAILURE
        }
        None => ExitCode::from(EXIT_NO_SCHED),
    }
}

fn simple<F>(ctx: &Ctx, f: F) -> ExitCode
where
    F: FnOnce(&mut Client) -> Result<String, ClientError>,
{
    match ctx.connect() {
        Ok((mut c, _)) => match f(&mut c) {
            Ok(r) => {
                if !r.is_empty() {
                    println!("{r}");
                }
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("rago-sched-hint : {e}");
                ExitCode::FAILURE
            }
        },
        Err(e) => {
            eprintln!("rago-sched-hint : {e}");
            ExitCode::from(EXIT_NO_SCHED)
        }
    }
}

fn read_sys(p: &str) -> String {
    std::fs::read_to_string(p)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "absent".into())
}

fn cmd_status(ctx: &Ctx) -> ExitCode {
    println!("sched_ext.state={}", read_sys("/sys/kernel/sched_ext/state"));
    println!("sched_ext.ops={}", read_sys("/sys/kernel/sched_ext/root/ops"));
    match ctx.connect() {
        Ok((mut c, _)) => match c.status() {
            Ok(kv) => {
                println!("scx_rago=running");
                for (k, v) in kv {
                    println!("{k}={v}");
                }
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("rago-sched-hint : {e}");
                ExitCode::FAILURE
            }
        },
        Err(e) => {
            println!("scx_rago=absent");
            ctx.info(&e.to_string());
            ExitCode::from(EXIT_NO_SCHED)
        }
    }
}

fn cmd_topology(ctx: &Ctx) -> ExitCode {
    match Topology::detect(&ctx.sysfs_root) {
        Ok(t) => {
            let dash = |s: &CpuSet| if s.is_empty() { "-".to_string() } else { s.to_string() };
            println!("topo={}", t.kind);
            println!("online={}", dash(&t.online));
            println!("game={}", dash(&t.game));
            println!("bg={}", dash(&t.bg));
            println!("confine={}", t.confine_by_default() as u8);
            println!("detail={}", t.detail);
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("rago-sched-hint : détection impossible : {e}");
            ExitCode::FAILURE
        }
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let ctx = Ctx {
        socket: cli.socket,
        sysfs_root: cli.sysfs_root,
        quiet: cli.quiet,
    };
    match cli.cmd {
        Cmd::Run {
            confine,
            render_comms,
            command,
        } => cmd_run(&ctx, confine, &render_comms, &command),
        Cmd::Tag { pid, confine } => cmd_tag(&ctx, pid, confine),
        Cmd::TagThread { tid } => simple(&ctx, |c| c.tag_thread(tid)),
        Cmd::Untag { pid } => simple(&ctx, |c| c.untag(pid)),
        Cmd::List => simple(&ctx, |c| {
            Ok(c.list()?
                .iter()
                .map(|e| e.to_line())
                .collect::<Vec<_>>()
                .join("\n"))
        }),
        Cmd::Status => cmd_status(&ctx),
        Cmd::Topology => cmd_topology(&ctx),
    }
}
