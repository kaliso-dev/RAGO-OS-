// SPDX-License-Identifier: GPL-2.0
//
// rago-profiled — profils par jeu (perf + sécurité) de Rago OS, module M14.
//
// Deux rôles dans un même binaire :
//
//   rago-profiled daemon               le démon root (service rago-profiled)
//   rago-profiled launch [...] -- CMD  le côté launcher (M11 / M2, en joueur)
//
// Lancement d'un jeu natif (couche proton) :
//
//   rago-profiled launch --steam-appid 1091500 -- <commande du jeu>
//   (option de lancement Steam : rago-profiled launch -- %command%)
//
//   1. demande au démon d'appliquer le profil du jeu (gouverneur, THP,
//      C-states, horloges GPU M9…) — ou le profil sûr par défaut ;
//   2. lance le jeu via `rago-sched-hint run` (M0) pour que scx_rago le tague
//      avant sa première instruction ;
//   3. attend la fin du jeu, puis le démon remet le réglage de base (M1).
//      Si ce processus est tué, le démon voit le socket se fermer et remet la
//      base quand même.
//
// Couche switch (jeux anti-triche, M6) : `rago-profiled prepare-switch --id X`
// juste avant le switch transmet le profil de sécurité Windows (hook M5/M6).
//
// Sans démon (pas encore installé, arrêté…), le jeu se lance quand même :
// réglage de base, hint ordonnanceur seulement.

mod daemon;
mod hooks;
mod linux;
mod profile;
mod proto;

use std::env;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Duration;

use clap::{Args, Parser, Subcommand, ValueEnum};

use crate::profile::{Couche, DEFAULT_PROFILE_DIRS, Effective, Query, Store, exe_key, parse_file};
use crate::proto::{
    Action, ActionStatus, DEFAULT_GROUP, DEFAULT_SOCKET, DEFAULT_STATE_DIR, MAX_LINE,
    PROTO_VERSION, Request, Response,
};

/// Le démon ne répond pas.
const EXIT_UNREACHABLE: u8 = 3;
/// Réglage demandé mais module pas encore installé (hook absent).
const EXIT_PENDING: u8 = 4;
/// Commande du jeu introuvable.
const EXIT_EXEC: u8 = 127;

#[derive(Parser, Debug)]
#[command(
    name = "rago-profiled",
    version,
    about = "Profils par jeu (perf + sécurité) de Rago OS : applique le profil d'un jeu à son lancement"
)]
struct Cli {
    /// Socket du démon.
    #[arg(long, env = "RAGO_PROFILED_SOCKET", default_value = DEFAULT_SOCKET, global = true)]
    socket: PathBuf,

    /// Dossier de profils (répétable, du plus prioritaire au moins prioritaire).
    /// Défaut : /etc/rago/profiles puis /usr/share/rago/profiles.
    #[arg(long = "profiles-dir", value_name = "DOSSIER", global = true)]
    profiles_dirs: Vec<PathBuf>,

    /// N'affiche que les erreurs.
    #[arg(short, long, global = true)]
    quiet: bool,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum CoucheArg {
    Proton,
    Switch,
}

impl From<CoucheArg> for Couche {
    fn from(c: CoucheArg) -> Self {
        match c {
            CoucheArg::Proton => Couche::Proton,
            CoucheArg::Switch => Couche::Switch,
        }
    }
}

/// Comment désigner le jeu.
#[derive(Args, Debug, Clone, Default)]
struct GameArgs {
    /// Identifiant Rago du jeu (nom du fichier de profil).
    #[arg(long)]
    id: Option<String>,
    /// AppID Steam (par défaut : variable SteamAppId posée par Steam).
    #[arg(long)]
    steam_appid: Option<u32>,
    /// Nom de l'exécutable (par défaut : deviné depuis la commande).
    #[arg(long)]
    exe: Option<String>,
    /// Couche voulue si aucun profil n'existe pour ce jeu.
    #[arg(long, value_enum)]
    couche: Option<CoucheArg>,
}

impl GameArgs {
    fn query(&self) -> Query {
        Query {
            id: self.id.clone(),
            steam_appid: self.steam_appid,
            exe: self.exe.clone(),
            couche: self.couche.map(Couche::from),
        }
    }
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Démon root : applique les profils demandés sur le socket.
    Daemon {
        /// Dossier d'état (photo du réglage de base pendant un jeu).
        #[arg(long, default_value = DEFAULT_STATE_DIR)]
        state_dir: PathBuf,
        /// Dossier des hooks (gpu-clocks pour M9, windows-security pour M5/M6).
        #[arg(long, default_value = hooks::DEFAULT_HOOKS_DIR)]
        hooks_dir: PathBuf,
        /// Groupe autorisé sur le socket ("" : réservé au propriétaire).
        #[arg(long, default_value = DEFAULT_GROUP)]
        group: String,
        /// Délai max d'un hook (secondes).
        #[arg(long, default_value_t = 15)]
        hook_timeout: u64,
        /// Racine du système (tests).
        #[arg(long, default_value = "/", hide = true)]
        root: PathBuf,
        /// Fichier PM QoS des C-states (tests).
        #[arg(long, default_value = "/dev/cpu_dma_latency", hide = true)]
        pmqos_dev: PathBuf,
    },
    /// Lance un jeu avec son profil : -- <commande du jeu>.
    Launch {
        #[command(flatten)]
        game: GameArgs,
        /// Chemin de rago-sched-hint (M0) ; défaut : cherché dans le PATH.
        #[arg(long, env = "RAGO_SCHED_HINT_BIN")]
        sched_hint_bin: Option<PathBuf>,
        /// Ne pas passer par rago-sched-hint.
        #[arg(long)]
        no_sched_hint: bool,
        /// Commande du jeu et ses arguments (après --).
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        command: Vec<String>,
    },
    /// Couche switch : transmet le profil de sécurité Windows avant le switch.
    PrepareSwitch {
        #[command(flatten)]
        game: GameArgs,
    },
    /// Sessions en cours et réglages actuels.
    Status {
        #[arg(long)]
        json: bool,
    },
    /// Profil effectif d'un jeu (sans rien appliquer).
    Show {
        #[command(flatten)]
        game: GameArgs,
        #[arg(long)]
        json: bool,
    },
    /// Liste les profils connus.
    List,
    /// Vérifie des fichiers ou dossiers de profils (base communautaire, CI).
    Validate {
        /// Fichiers ou dossiers (défaut : les dossiers de profils).
        paths: Vec<PathBuf>,
    },
}

struct Ctx {
    socket: PathBuf,
    dirs: Vec<PathBuf>,
    quiet: bool,
}

impl Ctx {
    fn info(&self, msg: &str) {
        if !self.quiet {
            eprintln!("rago-profiled : {msg}");
        }
    }

    fn warn(&self, msg: &str) {
        eprintln!("rago-profiled : attention : {msg}");
    }

    fn actions(&self, actions: &[Action]) {
        for a in actions {
            match a.status {
                ActionStatus::Error => eprintln!("  {a}"),
                _ if self.quiet => {}
                _ => eprintln!("  {a}"),
            }
        }
    }
}

// --- client du socket ----------------------------------------------------------------------

struct Conn {
    r: BufReader<UnixStream>,
    w: UnixStream,
}

impl Conn {
    fn open(path: &Path) -> io::Result<Self> {
        let s = UnixStream::connect(path)?;
        // Un hook (M9) peut prendre quelques secondes.
        s.set_read_timeout(Some(Duration::from_secs(60)))?;
        s.set_write_timeout(Some(Duration::from_secs(10)))?;
        Ok(Self {
            w: s.try_clone()?,
            r: BufReader::new(s),
        })
    }

    fn call(&mut self, req: &Request) -> io::Result<Response> {
        let mut line = serde_json::to_string(req).map_err(io::Error::other)?;
        line.push('\n');
        self.w.write_all(line.as_bytes())?;
        let mut back = String::new();
        let n = io::Read::take(&mut self.r, MAX_LINE as u64 + 1).read_line(&mut back)?;
        if n == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "le démon a fermé la connexion",
            ));
        }
        serde_json::from_str(back.trim_end())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }
}

fn call_once(socket: &Path, req: &Request) -> io::Result<Response> {
    Conn::open(socket)?.call(req)
}

// --- launch ---------------------------------------------------------------------------------

static CHILD: AtomicI32 = AtomicI32::new(0);

extern "C" fn forward_signal(sig: libc::c_int) {
    let pid = CHILD.load(Ordering::SeqCst);
    if pid > 0 {
        // SAFETY: kill est sûr dans un gestionnaire de signal.
        unsafe {
            libc::kill(pid, sig);
        }
    }
}

/// Après le lancement du jeu : SIGTERM / SIGHUP sont transmis au jeu (Steam
/// arrête un jeu ainsi), SIGINT / SIGQUIT ignorés (le terminal les envoie
/// déjà à tout le groupe, jeu compris) : on reste là pour remettre la base.
fn guard_signals(pid: u32) {
    CHILD.store(pid as i32, Ordering::SeqCst);
    // SAFETY: gestionnaires simples (kill), positionnés après le fork du jeu.
    unsafe {
        let h = forward_signal as extern "C" fn(libc::c_int) as libc::sighandler_t;
        libc::signal(libc::SIGTERM, h);
        libc::signal(libc::SIGHUP, h);
        libc::signal(libc::SIGINT, libc::SIG_IGN);
        libc::signal(libc::SIGQUIT, libc::SIG_IGN);
    }
}

/// Exécutable du jeu deviné depuis la commande : premier argument en .exe
/// (Proton : « proton waitforexitandrun …/Jeu.exe »), sinon la commande.
fn guess_exe(command: &[String]) -> Option<String> {
    command
        .iter()
        .find(|a| a.to_lowercase().ends_with(".exe"))
        .or(command.first())
        .map(|s| exe_key(s))
}

fn which(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path)
        .map(|d| d.join(name))
        .find(|p| p.is_file())
}

/// Commande réelle : le jeu, enveloppé par `rago-sched-hint run` si possible.
fn build_argv(
    ctx: &Ctx,
    eff: &Effective,
    hint_bin: Option<&Path>,
    no_hint: bool,
    command: &[String],
) -> Vec<String> {
    if no_hint || !eff.sched_hint.enabled {
        ctx.info("hint ordonnanceur désactivé pour ce lancement");
        return command.to_vec();
    }
    let bin = match hint_bin {
        Some(p) if p.is_file() => Some(p.to_path_buf()),
        Some(p) => {
            ctx.warn(&format!(
                "{} introuvable : jeu lancé sans hint ordonnanceur",
                p.display()
            ));
            None
        }
        None => {
            let found = which("rago-sched-hint");
            if found.is_none() {
                ctx.warn("rago-sched-hint (M0) introuvable dans le PATH : jeu lancé sans hint ordonnanceur");
            }
            found
        }
    };
    let Some(bin) = bin else {
        return command.to_vec();
    };
    let mut v = vec![
        bin.display().to_string(),
        "run".into(),
        "--confine".into(),
        eff.sched_hint.confine.to_string(),
    ];
    if ctx.quiet {
        v.push("--quiet".into());
    }
    for p in &eff.sched_hint.render_comm {
        v.push("--render-comm".into());
        v.push(p.clone());
    }
    v.push("--".into());
    v.extend(command.iter().cloned());
    v
}

fn describe(eff: &Effective) -> String {
    match &eff.fallback {
        Some(r) if eff.is_fallback() => r.clone(),
        _ => format!(
            "profil « {} » ({}, couche {}, trouvé par {}{})",
            eff.id,
            eff.name,
            eff.couche,
            eff.matched_by.as_deref().unwrap_or("?"),
            if eff.verified {
                ""
            } else {
                ", pas encore vérifié sur matériel"
            }
        ),
    }
}

fn cmd_launch(
    ctx: &Ctx,
    game: &GameArgs,
    hint_bin: Option<&Path>,
    no_hint: bool,
    command: &[String],
) -> ExitCode {
    let mut q = game.query();
    if q.id.is_none() && q.steam_appid.is_none() {
        q.steam_appid = ["SteamAppId", "SteamGameId"]
            .iter()
            .filter_map(|k| env::var(k).ok())
            .filter_map(|v| v.parse::<u32>().ok())
            .find(|n| *n > 0);
    }
    if q.exe.is_none() {
        q.exe = guess_exe(command);
    }
    let label =
        q.id.clone()
            .or_else(|| q.exe.clone())
            .unwrap_or_else(|| "jeu".into());

    let opened = Conn::open(&ctx.socket).and_then(|mut c| {
        let r = c.call(&Request::Apply {
            v: PROTO_VERSION,
            query: q.clone(),
            label: label.clone(),
        })?;
        Ok((c, r))
    });
    let (eff, mut conn) = match opened {
        Ok((c, resp)) if resp.ok && resp.profile.is_some() => {
            let eff = resp.profile.expect("vérifié");
            ctx.info(&describe(&eff));
            ctx.actions(&resp.actions);
            (eff, Some(c))
        }
        other => {
            let why = match other {
                Ok((_, r)) => r.error.unwrap_or_else(|| "réponse vide".into()),
                Err(e) => format!("{} : {e}", ctx.socket.display()),
            };
            ctx.warn(&format!(
                "démon rago-profiled injoignable ({why}) : jeu lancé avec le réglage de base, sans surcharge"
            ));
            // Le profil reste utile pour le hint ordonnanceur (motifs de rendu).
            let eff = Store::load(&ctx.dirs).resolve(&q);
            (eff, None)
        }
    };
    if eff.couche == Couche::Switch {
        ctx.warn(&format!(
            "« {} » est un jeu de couche switch : il se lance normalement par le Fast OS Switch (M6)",
            eff.id
        ));
    }

    let argv = build_argv(ctx, &eff, hint_bin, no_hint, command);
    let mut child = match Command::new(&argv[0]).args(&argv[1..]).spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!(
                "rago-profiled : impossible d'exécuter « {} » : {e}",
                argv[0]
            );
            if let Some(c) = conn.as_mut() {
                let _ = c.call(&Request::End);
            }
            return ExitCode::from(EXIT_EXEC);
        }
    };
    guard_signals(child.id());
    let status = loop {
        match child.wait() {
            Ok(s) => break Some(s),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => {
                ctx.warn(&format!("attente du jeu : {e}"));
                break None;
            }
        }
    };
    CHILD.store(0, Ordering::SeqCst);
    if let Some(mut c) = conn {
        match c.call(&Request::End) {
            Ok(r) => {
                ctx.info("jeu terminé : réglage de base remis");
                ctx.actions(&r.actions);
            }
            Err(e) => ctx.warn(&format!(
                "fin de session non confirmée ({e}) ; le démon remet la base dès la fermeture du socket"
            )),
        }
    }
    let code = match status {
        Some(s) => s.code().unwrap_or_else(|| 128 + s.signal().unwrap_or(0)),
        None => 1,
    };
    ExitCode::from(code.clamp(0, 255) as u8)
}

// --- autres commandes ----------------------------------------------------------------------

fn cmd_prepare_switch(ctx: &Ctx, game: &GameArgs) -> ExitCode {
    let req = Request::PrepareSwitch {
        v: PROTO_VERSION,
        query: game.query(),
    };
    match call_once(&ctx.socket, &req) {
        Ok(r) if r.ok => {
            if let Some(e) = &r.profile {
                ctx.info(&describe(e));
            }
            ctx.actions(&r.actions);
            if r.actions.iter().any(|a| a.status == ActionStatus::Error) {
                ExitCode::FAILURE
            } else if r.actions.iter().any(|a| a.status == ActionStatus::Pending) {
                ExitCode::from(EXIT_PENDING)
            } else {
                ExitCode::SUCCESS
            }
        }
        Ok(r) => {
            eprintln!("rago-profiled : {}", r.error.unwrap_or_default());
            ExitCode::FAILURE
        }
        Err(e) => {
            eprintln!(
                "rago-profiled : démon injoignable ({}) : {e}",
                ctx.socket.display()
            );
            ExitCode::from(EXIT_UNREACHABLE)
        }
    }
}

fn cmd_status(ctx: &Ctx, json: bool) -> ExitCode {
    match call_once(&ctx.socket, &Request::Status) {
        Ok(r) => {
            if json {
                println!("{}", serde_json::to_string_pretty(&r).unwrap_or_default());
                return ExitCode::SUCCESS;
            }
            if r.sessions.is_empty() {
                println!("aucun jeu en cours : réglage de base");
            }
            for s in &r.sessions {
                println!(
                    "session {} {} « {} » profil {} (uid {}, pid {}, depuis {} s)",
                    s.session,
                    if s.active { "ACTIVE" } else { "en dessous" },
                    s.label,
                    s.profile,
                    s.uid,
                    s.pid,
                    s.age_s
                );
            }
            for a in &r.actions {
                println!("{:<26} {}", a.knob, a.detail);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!(
                "rago-profiled : démon injoignable ({}) : {e}",
                ctx.socket.display()
            );
            ExitCode::from(EXIT_UNREACHABLE)
        }
    }
}

fn print_effective(e: &Effective) {
    let or = |o: Option<String>| o.unwrap_or_else(|| "base".into());
    println!("id               {}", e.id);
    println!("nom              {}", e.name);
    println!("couche           {}", e.couche);
    println!("source           {}", e.source);
    if let Some(r) = &e.fallback {
        println!("repli            {r}");
    }
    if let Some(m) = &e.matched_by {
        println!("trouvé par       {m}");
    }
    println!(
        "vérifié          {}",
        if e.verified {
            "oui"
        } else {
            "non (pas encore testé sur matériel)"
        }
    );
    println!("cpu_governor     {}", or(e.cpu_governor.clone()));
    println!("thp              {}", or(e.thp.map(|t| t.to_string())));
    println!("cstates          {}", or(e.cstates.map(|c| c.to_string())));
    let h = &e.sched_hint;
    println!(
        "sched_hint       {}",
        if h.enabled {
            format!(
                "confine {}{}",
                h.confine,
                if h.render_comm.is_empty() {
                    String::new()
                } else {
                    format!(", rendu {}", h.render_comm.join(" "))
                }
            )
        } else {
            "désactivé".into()
        }
    );
    let g = &e.gpu_clocks;
    println!(
        "gpu_clocks       {}{}{}",
        g.mode,
        g.core_mhz
            .map(|v| format!(" core {v} MHz"))
            .unwrap_or_default(),
        g.mem_mhz
            .map(|v| format!(" mem {v} MHz"))
            .unwrap_or_default()
    );
    println!(
        "mitigations      {}",
        e.mitigations
            .map(|m| m.to_string())
            .unwrap_or_else(|| "non demandé (noyau inchangé)".into())
    );
    println!("windows_security {}", e.windows_security);
    for w in &e.warnings {
        println!("attention        {w}");
    }
}

fn cmd_show(ctx: &Ctx, game: &GameArgs, json: bool) -> ExitCode {
    let store = Store::load(&ctx.dirs);
    let eff = store.resolve(&game.query());
    if json {
        println!("{}", serde_json::to_string_pretty(&eff).unwrap_or_default());
    } else {
        print_effective(&eff);
    }
    ExitCode::SUCCESS
}

fn cmd_list(ctx: &Ctx) -> ExitCode {
    let store = Store::load(&ctx.dirs);
    let mut v: Vec<_> = store.entries().collect();
    v.sort_by(|a, b| a.profile.id.cmp(&b.profile.id));
    for e in &v {
        println!(
            "{:<28} {:<7} {:<3} {:<34} {}",
            e.profile.id,
            e.profile.couche,
            if e.profile.verified { "ok" } else { "-" },
            e.profile.name,
            e.path.display()
        );
    }
    for n in &store.notes {
        eprintln!("note : {n}");
    }
    for err in &store.errors {
        eprintln!("refusé : {} : {}", err.path.display(), err.message);
    }
    if v.is_empty() {
        eprintln!(
            "aucun profil dans {}",
            ctx.dirs
                .iter()
                .map(|d| d.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    ExitCode::SUCCESS
}

fn cmd_validate(ctx: &Ctx, paths: &[PathBuf]) -> ExitCode {
    let (dirs, files): (Vec<PathBuf>, Vec<PathBuf>) = if paths.is_empty() {
        (ctx.dirs.clone(), Vec::new())
    } else {
        paths.iter().cloned().partition(|p| p.is_dir())
    };
    let mut bad = 0;
    let mut good = 0;
    for f in &files {
        match parse_file(f) {
            Ok((p, warnings)) => {
                good += 1;
                println!("OK      {} ({})", f.display(), p.id);
                for w in warnings {
                    println!("  attention : {w}");
                }
            }
            Err(e) => {
                bad += 1;
                println!("REFUSÉ  {} : {e}", f.display());
            }
        }
    }
    if !dirs.is_empty() {
        let store = Store::load(&dirs);
        let mut v: Vec<_> = store.entries().collect();
        v.sort_by(|a, b| a.path.cmp(&b.path));
        for e in v {
            good += 1;
            println!("OK      {} ({})", e.path.display(), e.profile.id);
            for w in &e.warnings {
                println!("  attention : {w}");
            }
        }
        for err in &store.errors {
            bad += 1;
            println!("REFUSÉ  {} : {}", err.path.display(), err.message);
        }
        for n in &store.notes {
            println!("note    {n}");
        }
    }
    println!("{good} profil(s) valide(s), {bad} refusé(s)");
    if bad > 0 {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let dirs = if cli.profiles_dirs.is_empty() {
        DEFAULT_PROFILE_DIRS.iter().map(PathBuf::from).collect()
    } else {
        cli.profiles_dirs.clone()
    };
    let ctx = Ctx {
        socket: cli.socket.clone(),
        dirs,
        quiet: cli.quiet,
    };
    match &cli.cmd {
        Cmd::Daemon {
            state_dir,
            hooks_dir,
            group,
            hook_timeout,
            root,
            pmqos_dev,
        } => daemon::run(daemon::Config {
            socket: ctx.socket.clone(),
            group: (!group.is_empty()).then(|| group.clone()),
            state_dir: state_dir.clone(),
            profile_dirs: ctx.dirs.clone(),
            hooks_dir: hooks_dir.clone(),
            root: root.clone(),
            pmqos_dev: pmqos_dev.clone(),
            hook_timeout: Duration::from_secs(*hook_timeout),
        }),
        Cmd::Launch {
            game,
            sched_hint_bin,
            no_sched_hint,
            command,
        } => cmd_launch(
            &ctx,
            game,
            sched_hint_bin.as_deref(),
            *no_sched_hint,
            command,
        ),
        Cmd::PrepareSwitch { game } => cmd_prepare_switch(&ctx, game),
        Cmd::Status { json } => cmd_status(&ctx, *json),
        Cmd::Show { game, json } => cmd_show(&ctx, game, *json),
        Cmd::List => cmd_list(&ctx),
        Cmd::Validate { paths } => cmd_validate(&ctx, paths),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guesses_the_game_exe() {
        let c = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            guess_exe(&c(&[
                "/x/proton",
                "waitforexitandrun",
                "/g/bin/x64/Cyberpunk2077.exe"
            ]))
            .as_deref(),
            Some("cyberpunk2077.exe")
        );
        assert_eq!(
            guess_exe(&c(&["/opt/cs2/cs2", "-novid"])).as_deref(),
            Some("cs2")
        );
    }

    #[test]
    fn argv_wraps_with_sched_hint() {
        let ctx = Ctx {
            socket: PathBuf::new(),
            dirs: Vec::new(),
            quiet: false,
        };
        let mut eff = Effective::fallback(Couche::Proton, "t".into());
        eff.sched_hint.render_comm = vec!["GameThread".into()];
        eff.sched_hint.confine = crate::profile::Confine::Off;
        let bin = env::current_exe().unwrap();
        let cmd = vec!["jeu".to_string(), "--arg".to_string()];
        let v = build_argv(&ctx, &eff, Some(&bin), false, &cmd);
        assert_eq!(
            &v[1..],
            &[
                "run",
                "--confine",
                "off",
                "--render-comm",
                "GameThread",
                "--",
                "jeu",
                "--arg"
            ]
        );
        assert_eq!(build_argv(&ctx, &eff, Some(&bin), true, &cmd), cmd);
        eff.sched_hint.enabled = false;
        assert_eq!(build_argv(&ctx, &eff, Some(&bin), false, &cmd), cmd);
        eff.sched_hint.enabled = true;
        assert_eq!(
            build_argv(
                &ctx,
                &eff,
                Some(Path::new("/absent/rago-sched-hint")),
                false,
                &cmd
            ),
            cmd
        );
    }
}
