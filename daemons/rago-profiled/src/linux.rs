// SPDX-License-Identifier: GPL-2.0
//
// Côté Linux d'un profil : gouverneur cpufreq, THP, C-states, contrôle des
// mitigations, et horloges GPU (hook M9).
//
// Règle de cohérence avec M1 : M1 pose le réglage de BASE (profil tuned
// rago-gaming) ; un profil de jeu le SURCHARGE le temps du jeu, puis la base
// revient exactement. Pour cela :
//   - avant la première surcharge, les valeurs de base sont photographiées et
//     écrites dans /run/rago-profiled/applied.json (si le démon meurt, il les
//     remet au redémarrage suivant ; /run est vidé au reboot, où tuned
//     réapplique de toute façon la base) ;
//   - seul ce que rago-profiled a changé est remis (marqueurs touched_*) ;
//   - les C-states passent par une demande PM QoS (/dev/cpu_dma_latency),
//     comme le force_latency de tuned : le noyau garde la plus stricte des
//     demandes, donc un profil peut AJOUTER une limite (shallow, poll) mais ne
//     peut pas relâcher celle de M1. La demande disparaît quand le fichier est
//     fermé, même si le démon est tué.
//   - mitigations : réglage global du noyau (ligne de commande, M0). Le démon
//     le compare au profil et le signale ; il ne le change jamais.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::hooks::{HOOK_GPU_CLOCKS, HookOutcome, Hooks};
use crate::profile::{CStates, Effective, GpuMode, Mitigations, Thp};
use crate::proto::{Action, ActionStatus as S};

/// Valeur de /dev/cpu_dma_latency sans aucune demande (PM_QOS_DEFAULT_VALUE).
pub const PMQOS_DEFAULT_US: i32 = 2_000_000_000;
/// Repli de « shallow » si l'état C1 n'est pas lisible (comme tuned : `cstate.id_no_zero:1|3`).
pub const SHALLOW_FALLBACK_US: i32 = 3;

const CPUFREQ: &str = "sys/devices/system/cpu/cpufreq";
const THP: &str = "sys/kernel/mm/transparent_hugepage/enabled";
const C1_LATENCY: &str = "sys/devices/system/cpu/cpu0/cpuidle/state1/latency";
const CMDLINE: &str = "proc/cmdline";
const M1_CONF: &str = "etc/rago/host-tuning.conf";

fn read_trim(p: &Path) -> Option<String> {
    fs::read_to_string(p).ok().map(|s| s.trim().to_string())
}

/// Écrit une valeur dans un fichier sysfs existant (jamais de création).
fn write_sys(p: &Path, v: &str) -> io::Result<()> {
    let mut f = OpenOptions::new().write(true).truncate(true).open(p)?;
    f.write_all(v.as_bytes())
}

/// Accès au système, sous une racine (« / » en vrai, une fausse racine en test).
#[derive(Clone, Debug)]
pub struct System {
    root: PathBuf,
    pmqos_dev: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyState {
    pub policy: String,
    pub governor: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub epp: Option<String>,
}

impl System {
    pub fn new(root: PathBuf, pmqos_dev: PathBuf) -> Self {
        Self { root, pmqos_dev }
    }

    fn p(&self, rel: &str) -> PathBuf {
        self.root.join(rel)
    }

    fn policy_dir(&self, name: &str) -> PathBuf {
        self.p(CPUFREQ).join(name)
    }

    /// Politiques cpufreq (policy0, policy1…), dans l'ordre numérique.
    pub fn policies(&self) -> Vec<String> {
        let Ok(rd) = fs::read_dir(self.p(CPUFREQ)) else {
            return Vec::new();
        };
        let mut v: Vec<(u32, String)> = rd
            .flatten()
            .filter_map(|e| {
                let n = e.file_name().to_string_lossy().to_string();
                let num = n.strip_prefix("policy")?.parse().ok()?;
                e.path()
                    .join("scaling_governor")
                    .exists()
                    .then_some((num, n))
            })
            .collect();
        v.sort();
        v.into_iter().map(|(_, n)| n).collect()
    }

    pub fn read_policy(&self, name: &str) -> Option<PolicyState> {
        let d = self.policy_dir(name);
        Some(PolicyState {
            policy: name.into(),
            governor: read_trim(&d.join("scaling_governor"))?,
            epp: read_trim(&d.join("energy_performance_preference")),
        })
    }

    pub fn available_governors(&self, name: &str) -> Option<Vec<String>> {
        read_trim(&self.policy_dir(name).join("scaling_available_governors"))
            .map(|s| s.split_whitespace().map(String::from).collect())
    }

    pub fn set_governor(&self, name: &str, g: &str) -> io::Result<()> {
        write_sys(&self.policy_dir(name).join("scaling_governor"), g)
    }

    pub fn set_epp(&self, name: &str, v: &str) -> io::Result<()> {
        write_sys(
            &self.policy_dir(name).join("energy_performance_preference"),
            v,
        )
    }

    /// Mode THP actif : « always [madvise] never » -> « madvise ».
    pub fn thp(&self) -> Option<String> {
        let s = read_trim(&self.p(THP))?;
        match (s.find('['), s.find(']')) {
            (Some(a), Some(b)) if a < b => Some(s[a + 1..b].to_string()),
            _ => Some(s),
        }
    }

    pub fn set_thp(&self, v: &str) -> io::Result<()> {
        write_sys(&self.p(THP), v)
    }

    /// Mitigations du noyau en cours (dernier `mitigations=` de la ligne de
    /// commande, avant `--`). Tout sauf « off » veut dire actives.
    pub fn kernel_mitigations(&self) -> Mitigations {
        let line = read_trim(&self.p(CMDLINE)).unwrap_or_default();
        let mut last = None;
        for tok in line.split_whitespace() {
            if tok == "--" {
                break;
            }
            if let Some(v) = tok.strip_prefix("mitigations=") {
                last = Some(v.to_string());
            }
        }
        match last.as_deref() {
            Some("off") => Mitigations::Off,
            _ => Mitigations::On,
        }
    }

    /// Mode C-states de base choisi dans M1 (RAGO_CSTATES de
    /// /etc/rago/host-tuning.conf), None si M1 n'est pas installé.
    pub fn m1_cstates(&self) -> Option<CStates> {
        let text = fs::read_to_string(self.p(M1_CONF)).ok()?;
        let line = text
            .lines()
            .rev()
            .find(|l| l.trim_start().starts_with("RAGO_CSTATES="))?;
        let v = line.trim_start().trim_start_matches("RAGO_CSTATES=").trim();
        let v = v.trim_matches('"').trim_matches('\'');
        CStates::parse(v)
    }

    /// Limite « shallow » en µs : latence de sortie de l'état C1 du CPU 0
    /// (si non nulle), sinon 3 µs — exactement le `cstate.id_no_zero:1|3`
    /// de latency-performance utilisé par M1.
    pub fn shallow_latency_us(&self) -> i32 {
        read_trim(&self.p(C1_LATENCY))
            .and_then(|s| s.parse::<i32>().ok())
            .filter(|v| *v > 0)
            .unwrap_or(SHALLOW_FALLBACK_US)
    }

    pub fn pmqos_dev(&self) -> &Path {
        &self.pmqos_dev
    }

    /// Latence effective (µs) que le noyau impose aux C-states.
    pub fn pmqos_effective(&self) -> Option<i32> {
        let mut f = File::open(&self.pmqos_dev).ok()?;
        let mut b = [0u8; 4];
        f.read_exact(&mut b).ok()?;
        Some(i32::from_ne_bytes(b))
    }

    /// Ouvre une demande PM QoS ; elle tient tant que le fichier est ouvert.
    pub fn open_pmqos(&self, us: i32) -> io::Result<File> {
        let mut f = OpenOptions::new().write(true).open(&self.pmqos_dev)?;
        f.write_all(&us.to_ne_bytes())?;
        Ok(f)
    }
}

/// Réglage de base photographié avant la première surcharge.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Saved {
    pub governors: Vec<PolicyState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thp: Option<String>,
    #[serde(default)]
    pub touched_governor: bool,
    #[serde(default)]
    pub touched_thp: bool,
    #[serde(default)]
    pub gpu_applied: bool,
}

struct Hold {
    _file: File,
    us: i32,
    mode: CStates,
}

pub struct Applier {
    sys: System,
    hooks: Hooks,
    state_file: PathBuf,
    saved: Option<Saved>,
    pmqos: Option<Hold>,
}

fn base_label(b: Option<CStates>) -> String {
    match b {
        Some(m) => format!("base M1 : {m}"),
        None => "M1 non installé".into(),
    }
}

impl Applier {
    pub fn new(sys: System, hooks: Hooks, state_file: PathBuf) -> Self {
        Self {
            sys,
            hooks,
            state_file,
            saved: None,
            pmqos: None,
        }
    }

    pub fn system(&self) -> &System {
        &self.sys
    }

    pub fn saved(&self) -> Option<&Saved> {
        self.saved.as_ref()
    }

    /// Mode et valeur (µs) de la demande C-states tenue, s'il y en a une.
    pub fn cstates_hold(&self) -> Option<(CStates, i32)> {
        self.pmqos.as_ref().map(|h| (h.mode, h.us))
    }

    fn snapshot(&self) -> Saved {
        Saved {
            governors: self
                .sys
                .policies()
                .iter()
                .filter_map(|p| self.sys.read_policy(p))
                .collect(),
            thp: self.sys.thp(),
            ..Default::default()
        }
    }

    fn persist(&self) -> Option<Action> {
        let saved = self.saved.as_ref()?;
        let res = (|| -> io::Result<()> {
            if let Some(d) = self.state_file.parent() {
                fs::create_dir_all(d)?;
            }
            let tmp = self.state_file.with_extension("tmp");
            let mut f = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&tmp)?;
            f.write_all(serde_json::to_string_pretty(saved)?.as_bytes())?;
            f.sync_all()?;
            fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
            fs::rename(&tmp, &self.state_file)
        })();
        res.err().map(|e| {
            Action::new(
                "etat",
                S::Error,
                format!(
                    "{} non écrit ({e}) : si le démon meurt, la base ne sera pas remise seule",
                    self.state_file.display()
                ),
            )
        })
    }

    /// Au démarrage : si une instance précédente est morte avec un profil
    /// appliqué, remet sa photo du réglage de base.
    pub fn recover(&mut self) -> Vec<Action> {
        let text = match fs::read_to_string(&self.state_file) {
            Ok(t) => t,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Vec::new(),
            Err(e) => {
                return vec![Action::new(
                    "reprise",
                    S::Error,
                    format!("{} illisible : {e}", self.state_file.display()),
                )];
            }
        };
        match serde_json::from_str::<Saved>(&text) {
            Ok(s) => {
                self.saved = Some(s);
                let mut out = vec![Action::new(
                    "reprise",
                    S::Info,
                    "profil laissé par une instance arrêtée brutalement : réglage de base remis",
                )];
                out.extend(self.restore());
                out
            }
            Err(e) => {
                let _ = fs::remove_file(&self.state_file);
                vec![Action::new(
                    "reprise",
                    S::Error,
                    format!("{} invalide ({e}) : supprimé", self.state_file.display()),
                )]
            }
        }
    }

    /// Applique le côté Linux d'un profil par-dessus la base. Appelé à chaque
    /// changement du profil actif (nouvelle session, fin de la session du
    /// dessus) : un réglage absent du profil revient à la base.
    pub fn apply(&mut self, eff: &Effective) -> Vec<Action> {
        let mut out = Vec::new();
        if self.saved.is_none() {
            self.saved = Some(self.snapshot());
        }
        // Sûreté en cas de mort du démon PENDANT l'application : le fichier
        // d'état marque d'abord comme « touché » tout ce que ce profil va
        // changer, AVANT la première écriture. Une reprise remettrait au pire
        // une valeur déjà à la base (sans effet). En mémoire, les marqueurs
        // exacts sont recalculés par chaque réglage.
        let exact = self.saved.clone();
        if let Some(s) = self.saved.as_mut() {
            s.touched_governor |= eff.cpu_governor.is_some();
            s.touched_thp |= eff.thp.is_some();
            s.gpu_applied |= eff.gpu_clocks.mode != GpuMode::Auto;
        }
        if let Some(a) = self.persist() {
            out.push(a);
        }
        self.saved = exact;
        out.push(self.apply_governor(eff.cpu_governor.as_deref()));
        out.push(self.apply_thp(eff.thp));
        out.push(self.apply_cstates(eff.cstates));
        if let Some(a) = self.check_mitigations(eff.mitigations) {
            out.push(a);
        }
        out.push(self.apply_gpu(eff));
        if let Some(a) = self.persist() {
            out.push(a);
        }
        out
    }

    fn apply_governor(&mut self, want: Option<&str>) -> Action {
        const K: &str = "cpu_governor";
        let saved = self.saved.as_mut().expect("photo prise");
        if want.is_none() && !saved.touched_governor {
            return Action::new(K, S::Skipped, "non demandé : base M1 gardée");
        }
        if saved.governors.is_empty() {
            let what = if want.is_some() {
                "gouverneur non modifiable"
            } else {
                "rien à remettre"
            };
            return Action::new(
                K,
                S::Skipped,
                format!("cpufreq absent sur cette machine : {what}"),
            );
        }
        let bases = saved.governors.clone();
        let mut touched = saved.touched_governor;
        let (mut changed, mut same, mut errors, mut unavailable) = (0, 0, Vec::new(), Vec::new());
        for base in &bases {
            // Cible : le gouverneur du profil s'il est proposé, sinon la base.
            let target = match want {
                Some(g) => match self.sys.available_governors(&base.policy) {
                    Some(av) if !av.iter().any(|a| a == g) => {
                        unavailable.push(format!("{} ({})", base.policy, av.join(" ")));
                        base.governor.as_str()
                    }
                    _ => g,
                },
                None => base.governor.as_str(),
            };
            let cur = self.sys.read_policy(&base.policy).map(|p| p.governor);
            if cur.as_deref() == Some(target) {
                same += 1;
                continue;
            }
            match self.sys.set_governor(&base.policy, target) {
                Ok(()) => {
                    let back = self.sys.read_policy(&base.policy);
                    if back.as_ref().map(|p| p.governor.as_str()) == Some(target) {
                        changed += 1;
                    } else {
                        errors.push(format!(
                            "{} : relu {:?} au lieu de {target}",
                            base.policy,
                            back.map(|p| p.governor)
                        ));
                    }
                    if target == base.governor {
                        // Retour à la base : amd-pstate / intel_pstate actifs
                        // changent la préférence énergie/perf avec le
                        // gouverneur ; on remet aussi celle de la base.
                        if let (Some(epp), Some(now)) = (
                            &base.epp,
                            self.sys.read_policy(&base.policy).and_then(|p| p.epp),
                        ) && &now != epp
                        {
                            let _ = self.sys.set_epp(&base.policy, epp);
                        }
                    } else {
                        touched = true;
                    }
                }
                Err(e) => errors.push(format!("{} : {e}", base.policy)),
            }
        }
        let total = bases.len();
        if want.is_none() {
            touched = !errors.is_empty();
        }
        saved.touched_governor = touched;
        let mut detail = match want {
            Some(g) => {
                format!("{g} : {changed}/{total} politique(s) changée(s), {same} déjà bonne(s)")
            }
            None => format!("base remise : {changed}/{total} politique(s), {same} déjà bonne(s)"),
        };
        if !unavailable.is_empty() {
            detail.push_str(&format!(
                " ; non proposé, base gardée sur {}",
                unavailable.join(", ")
            ));
        }
        if !errors.is_empty() {
            detail.push_str(&format!(" ; échecs : {}", errors.join(", ")));
            return Action::new(K, S::Error, detail);
        }
        let status = match (want, changed) {
            (None, _) => S::Restored,
            (Some(_), 0) if unavailable.len() == total => S::Skipped,
            (Some(_), 0) => S::Unchanged,
            (Some(_), _) => S::Applied,
        };
        Action::new(K, status, detail)
    }

    fn apply_thp(&mut self, want: Option<Thp>) -> Action {
        const K: &str = "thp";
        let saved = self.saved.as_mut().expect("photo prise");
        if want.is_none() && !saved.touched_thp {
            return Action::new(K, S::Skipped, "non demandé : base M1 gardée");
        }
        let Some(base) = saved.thp.clone() else {
            return Action::new(
                K,
                S::Skipped,
                "THP absent (noyau sans transparent hugepages)",
            );
        };
        let target = want.map(|t| t.as_str().to_string()).unwrap_or(base.clone());
        if self.sys.thp().as_deref() == Some(target.as_str()) {
            if want.is_none() {
                saved.touched_thp = false;
                return Action::new(K, S::Restored, format!("base {base} déjà en place"));
            }
            return Action::new(K, S::Unchanged, format!("déjà {target}"));
        }
        if let Err(e) = self.sys.set_thp(&target) {
            return Action::new(
                K,
                S::Error,
                format!("écriture de {target} impossible : {e}"),
            );
        }
        let back = self.sys.thp();
        if back.as_deref() != Some(target.as_str()) {
            return Action::new(K, S::Error, format!("relu {back:?} au lieu de {target}"));
        }
        if want.is_none() {
            saved.touched_thp = false;
            Action::new(K, S::Restored, format!("base {base} remise"))
        } else {
            saved.touched_thp = target != base;
            Action::new(K, S::Applied, format!("{target} (base M1 : {base})"))
        }
    }

    fn apply_cstates(&mut self, want: Option<CStates>) -> Action {
        const K: &str = "cstates";
        let base = self.sys.m1_cstates();
        let mode = match want {
            None | Some(CStates::Deep) => {
                let had = self.pmqos.take().is_some();
                let mut d = format!("aucune limite ajoutée ({})", base_label(base));
                if want == Some(CStates::Deep) && base.is_some_and(|b| b != CStates::Deep) {
                    d.push_str(
                        " : la base M1 reste plus stricte, un profil ne peut qu'ajouter une limite",
                    );
                }
                if had {
                    return Action::new(
                        K,
                        S::Restored,
                        format!("limite du jeu précédent retirée ; {d}"),
                    );
                }
                let st = if want.is_some() {
                    S::Unchanged
                } else {
                    S::Skipped
                };
                return Action::new(K, st, d);
            }
            Some(m) => m,
        };
        let us = match mode {
            CStates::Poll => 0,
            _ => self.sys.shallow_latency_us(),
        };
        if let Some(h) = &self.pmqos
            && h.us == us
        {
            return Action::new(
                K,
                S::Unchanged,
                format!("{mode} : limite {us} µs déjà tenue"),
            );
        }
        match self.sys.open_pmqos(us) {
            Ok(f) => {
                // La nouvelle demande est posée avant que l'ancienne ne tombe.
                self.pmqos = Some(Hold { _file: f, us, mode });
                let eff = self
                    .sys
                    .pmqos_effective()
                    .map(|v| format!("{v} µs"))
                    .unwrap_or_else(|| "illisible".into());
                Action::new(
                    K,
                    S::Applied,
                    format!(
                        "{mode} : limite {us} µs (latence effective {eff} ; {})",
                        base_label(base)
                    ),
                )
            }
            Err(e) => Action::new(
                K,
                S::Error,
                format!(
                    "{} : {e} (C-states laissés à la base)",
                    self.sys.pmqos_dev().display()
                ),
            ),
        }
    }

    fn check_mitigations(&self, want: Option<Mitigations>) -> Option<Action> {
        const K: &str = "mitigations";
        let want = want?;
        let run = self.sys.kernel_mitigations();
        let kernel = match run {
            Mitigations::On => "actives",
            Mitigations::Off => "coupées (mitigations=off)",
        };
        Some(if want == run {
            Action::new(
                K,
                S::Unchanged,
                format!("noyau déjà conforme : mitigations {kernel}"),
            )
        } else if want == Mitigations::Off {
            Action::new(
                K,
                S::Skipped,
                format!(
                    "le profil propose off, le noyau les a {kernel} : non modifié (réglage global du noyau, \
                     RAGO_MITIGATIONS=off dans /etc/rago/kernel.conf puis redémarrage — choix du joueur, voir M0)"
                ),
            )
        } else {
            Action::new(
                K,
                S::Info,
                format!(
                    "ATTENTION : ce profil veut les mitigations, le noyau les a {kernel} \
                     (RAGO_MITIGATIONS=auto dans /etc/rago/kernel.conf puis redémarrage)"
                ),
            )
        })
    }

    fn gpu_hook(&self, verb: &str, eff: Option<&Effective>) -> HookOutcome {
        let mut env = Vec::new();
        let mut json = String::from("{}");
        if let Some(e) = eff {
            env.push(("RAGO_PROFILE_ID", e.id.clone()));
            env.push(("RAGO_GPU_CLOCKS_MODE", e.gpu_clocks.mode.to_string()));
            if let Some(c) = e.gpu_clocks.core_mhz {
                env.push(("RAGO_GPU_CORE_MHZ", c.to_string()));
            }
            if let Some(m) = e.gpu_clocks.mem_mhz {
                env.push(("RAGO_GPU_MEM_MHZ", m.to_string()));
            }
            json = serde_json::to_string(e).unwrap_or(json);
        }
        self.hooks.run(HOOK_GPU_CLOCKS, &[verb], &env, &json)
    }

    fn apply_gpu(&mut self, eff: &Effective) -> Action {
        const K: &str = "gpu_clocks";
        let applied = self.saved.as_ref().is_some_and(|s| s.gpu_applied);
        if eff.gpu_clocks.mode == GpuMode::Auto {
            if !applied {
                return Action::new(K, S::Skipped, "auto : pas de surcharge");
            }
            return self.gpu_restore();
        }
        let what = match eff.gpu_clocks.mode {
            GpuMode::Fixed => format!(
                "fixed (core {} MHz, mem {} MHz)",
                eff.gpu_clocks
                    .core_mhz
                    .map(|v| v.to_string())
                    .unwrap_or("-".into()),
                eff.gpu_clocks
                    .mem_mhz
                    .map(|v| v.to_string())
                    .unwrap_or("-".into())
            ),
            m => m.to_string(),
        };
        match self.gpu_hook("apply", Some(eff)) {
            HookOutcome::Ok(msg) => {
                if let Some(s) = self.saved.as_mut() {
                    s.gpu_applied = true;
                }
                Action::new(
                    K,
                    S::Applied,
                    format!("{what} via le hook M9 {msg}").trim().to_string(),
                )
            }
            HookOutcome::Absent => Action::new(
                K,
                S::Pending,
                format!(
                    "{what} demandé ; M9 (GPU) pas encore installé : hook {} absent, horloges non modifiées",
                    self.hooks.path(HOOK_GPU_CLOCKS).display()
                ),
            ),
            HookOutcome::Refused(m) => Action::new(K, S::Error, format!("hook refusé : {m}")),
            HookOutcome::Failed(m) => Action::new(K, S::Error, format!("hook en échec : {m}")),
        }
    }

    fn gpu_restore(&mut self) -> Action {
        const K: &str = "gpu_clocks";
        let r = self.gpu_hook("restore", None);
        if let Some(s) = self.saved.as_mut() {
            s.gpu_applied = false;
        }
        match r {
            HookOutcome::Ok(_) => Action::new(K, S::Restored, "horloges de base remises (hook M9)"),
            HookOutcome::Absent => Action::new(
                K,
                S::Error,
                "hook M9 disparu : horloges peut-être pas remises",
            ),
            HookOutcome::Refused(m) | HookOutcome::Failed(m) => {
                Action::new(K, S::Error, format!("remise des horloges : {m}"))
            }
        }
    }

    /// Remet tout le réglage de base (fin de la dernière session, arrêt du
    /// démon, reprise après un arrêt brutal).
    pub fn restore(&mut self) -> Vec<Action> {
        let mut out = Vec::new();
        let Some(saved) = self.saved.clone() else {
            if self.pmqos.take().is_some() {
                out.push(Action::new("cstates", S::Restored, "limite retirée"));
            }
            return out;
        };
        if saved.touched_governor {
            out.push(self.apply_governor(None));
        }
        if saved.touched_thp {
            out.push(self.apply_thp(None));
        }
        if self.pmqos.take().is_some() {
            out.push(Action::new(
                "cstates",
                S::Restored,
                format!("limite retirée ({})", base_label(self.sys.m1_cstates())),
            ));
        }
        if saved.gpu_applied {
            out.push(self.gpu_restore());
        }
        let clean = self
            .saved
            .as_ref()
            .is_some_and(|s| !s.touched_governor && !s.touched_thp && !s.gpu_applied);
        if clean {
            self.saved = None;
            if let Err(e) = fs::remove_file(&self.state_file)
                && e.kind() != io::ErrorKind::NotFound
            {
                out.push(Action::new(
                    "etat",
                    S::Error,
                    format!("{} : {e}", self.state_file.display()),
                ));
            }
        } else if let Some(a) = self.persist() {
            out.push(a);
        }
        if out.is_empty() {
            out.push(Action::new("base", S::Unchanged, "rien n'avait été changé"));
        }
        out
    }
}

/// Fausse racine pour les tests (cpufreq, THP, cpuidle, cmdline, conf M1).
#[cfg(test)]
pub mod fake {
    use super::*;

    pub struct FakeRoot {
        pub dir: tempfile::TempDir,
    }

    impl FakeRoot {
        /// `govs` : gouverneur initial de chaque politique.
        pub fn new(govs: &[&str], available: &str) -> Self {
            let dir = tempfile::tempdir().unwrap();
            let r = dir.path();
            for (i, g) in govs.iter().enumerate() {
                let d = r.join(CPUFREQ).join(format!("policy{i}"));
                fs::create_dir_all(&d).unwrap();
                fs::write(d.join("scaling_governor"), format!("{g}\n")).unwrap();
                fs::write(
                    d.join("scaling_available_governors"),
                    format!("{available}\n"),
                )
                .unwrap();
                fs::write(d.join("energy_performance_preference"), "performance\n").unwrap();
            }
            let t = r.join(THP);
            fs::create_dir_all(t.parent().unwrap()).unwrap();
            fs::write(&t, "always [madvise] never\n").unwrap();
            let c = r.join(C1_LATENCY);
            fs::create_dir_all(c.parent().unwrap()).unwrap();
            fs::write(&c, "1\n").unwrap();
            fs::create_dir_all(r.join("proc")).unwrap();
            fs::write(
                r.join(CMDLINE),
                "BOOT_IMAGE=/vmlinuz root=/dev/x quiet threadirqs\n",
            )
            .unwrap();
            fs::create_dir_all(r.join("etc/rago")).unwrap();
            fs::write(r.join(M1_CONF), "# M1\nRAGO_CSTATES=\"deep\"\n").unwrap();
            fs::create_dir_all(r.join("dev")).unwrap();
            fs::write(
                r.join("dev/cpu_dma_latency"),
                PMQOS_DEFAULT_US.to_ne_bytes(),
            )
            .unwrap();
            fs::create_dir_all(r.join("hooks")).unwrap();
            fs::set_permissions(r.join("hooks"), fs::Permissions::from_mode(0o755)).unwrap();
            Self { dir }
        }

        pub fn root(&self) -> &Path {
            self.dir.path()
        }

        pub fn system(&self) -> System {
            System::new(
                self.root().to_path_buf(),
                self.root().join("dev/cpu_dma_latency"),
            )
        }

        pub fn hooks(&self) -> Hooks {
            Hooks::new(self.root().join("hooks"), std::time::Duration::from_secs(5))
        }

        pub fn applier(&self) -> Applier {
            Applier::new(
                self.system(),
                self.hooks(),
                self.root().join("run/applied.json"),
            )
        }

        pub fn gov(&self, i: usize) -> String {
            read_trim(
                &self
                    .root()
                    .join(CPUFREQ)
                    .join(format!("policy{i}/scaling_governor")),
            )
            .unwrap()
        }

        pub fn set_gov(&self, i: usize, g: &str) {
            fs::write(
                self.root()
                    .join(CPUFREQ)
                    .join(format!("policy{i}/scaling_governor")),
                g,
            )
            .unwrap();
        }

        pub fn thp(&self) -> String {
            self.system().thp().unwrap()
        }

        pub fn write(&self, rel: &str, body: &str) {
            let p = self.root().join(rel);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, body).unwrap();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::FakeRoot;
    use super::*;
    use crate::profile::{Couche, GpuClocks};

    fn eff() -> Effective {
        Effective::fallback(Couche::Proton, "test".into())
    }

    fn status_of(a: &[Action], knob: &str) -> S {
        a.iter()
            .find(|x| x.knob == knob)
            .unwrap_or_else(|| panic!("{knob} absent : {a:?}"))
            .status
    }

    #[test]
    fn profile_overrides_then_base_comes_back_exactly() {
        let f = FakeRoot::new(&["performance", "performance"], "performance powersave");
        let mut a = f.applier();
        let mut e = eff();
        e.cpu_governor = Some("powersave".into());
        e.thp = Some(Thp::Always);
        e.cstates = Some(CStates::Shallow);
        let r = a.apply(&e);
        assert_eq!(status_of(&r, "cpu_governor"), S::Applied, "{r:?}");
        assert_eq!(status_of(&r, "thp"), S::Applied);
        assert_eq!(status_of(&r, "cstates"), S::Applied);
        assert_eq!(f.gov(0), "powersave");
        assert_eq!(f.gov(1), "powersave");
        assert_eq!(f.thp(), "always");
        assert_eq!(a.cstates_hold(), Some((CStates::Shallow, 1)));
        assert_eq!(a.system().pmqos_effective(), Some(1));
        assert!(f.root().join("run/applied.json").exists());
        let saved: Saved =
            serde_json::from_str(&fs::read_to_string(f.root().join("run/applied.json")).unwrap())
                .unwrap();
        assert_eq!(saved.governors[0].governor, "performance");
        assert_eq!(saved.thp.as_deref(), Some("madvise"));
        assert!(saved.touched_governor && saved.touched_thp);

        let r = a.restore();
        assert!(r.iter().all(|x| x.status == S::Restored), "{r:?}");
        assert_eq!(f.gov(0), "performance");
        assert_eq!(f.gov(1), "performance");
        assert_eq!(f.thp(), "madvise");
        assert_eq!(a.cstates_hold(), None);
        assert!(!f.root().join("run/applied.json").exists());
        assert!(a.saved().is_none());
    }

    #[test]
    fn fallback_profile_changes_nothing() {
        let f = FakeRoot::new(&["performance"], "performance powersave");
        let mut a = f.applier();
        let r = a.apply(&eff());
        for k in ["cpu_governor", "thp", "cstates", "gpu_clocks"] {
            assert_eq!(status_of(&r, k), S::Skipped, "{k} : {r:?}");
        }
        assert!(!r.iter().any(|x| x.knob == "mitigations"));
        assert_eq!(f.gov(0), "performance");
        assert_eq!(f.thp(), "madvise");
        assert_eq!(a.cstates_hold(), None);
        let r = a.restore();
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].status, S::Unchanged);
    }

    #[test]
    fn already_good_values_are_not_rewritten_nor_restored() {
        let f = FakeRoot::new(&["performance", "performance"], "performance powersave");
        let mut a = f.applier();
        let mut e = eff();
        e.cpu_governor = Some("performance".into());
        e.thp = Some(Thp::Madvise);
        let r = a.apply(&e);
        assert_eq!(status_of(&r, "cpu_governor"), S::Unchanged);
        assert_eq!(status_of(&r, "thp"), S::Unchanged);
        // Quelqu'un d'autre change le gouverneur pendant le jeu : on ne
        // l'écrase pas à la fin, puisqu'on n'y avait pas touché.
        f.set_gov(0, "schedutil");
        a.restore();
        assert_eq!(f.gov(0), "schedutil");
    }

    #[test]
    fn unavailable_governor_keeps_base_and_says_so() {
        let f = FakeRoot::new(&["performance", "performance"], "performance powersave");
        let mut a = f.applier();
        let mut e = eff();
        e.cpu_governor = Some("schedutil".into());
        let r = a.apply(&e);
        let g = r.iter().find(|x| x.knob == "cpu_governor").unwrap();
        assert_eq!(g.status, S::Skipped, "{g:?}");
        assert!(g.detail.contains("non proposé"), "{g:?}");
        assert_eq!(f.gov(0), "performance");
    }

    #[test]
    fn switching_profiles_resets_fields_the_new_one_does_not_set() {
        let f = FakeRoot::new(&["performance"], "performance powersave");
        let mut a = f.applier();
        let mut first = eff();
        first.thp = Some(Thp::Always);
        first.cstates = Some(CStates::Poll);
        a.apply(&first);
        assert_eq!(f.thp(), "always");
        assert_eq!(a.cstates_hold(), Some((CStates::Poll, 0)));
        let mut second = eff();
        second.cpu_governor = Some("powersave".into());
        let r = a.apply(&second);
        assert_eq!(status_of(&r, "thp"), S::Restored);
        assert_eq!(status_of(&r, "cstates"), S::Restored);
        assert_eq!(f.thp(), "madvise");
        assert_eq!(f.gov(0), "powersave");
        assert_eq!(a.cstates_hold(), None);
        a.restore();
        assert_eq!(f.gov(0), "performance");
    }

    #[test]
    fn cstates_follow_m1_vocabulary() {
        let f = FakeRoot::new(&["performance"], "performance");
        // Pas d'état C1 lisible : 3 µs, comme tuned.
        fs::remove_file(f.root().join(C1_LATENCY)).unwrap();
        let mut a = f.applier();
        let mut e = eff();
        e.cstates = Some(CStates::Shallow);
        a.apply(&e);
        assert_eq!(a.cstates_hold(), Some((CStates::Shallow, 3)));
        // Base M1 plus stricte que « deep » demandé : signalé, pas relâché.
        f.write(M1_CONF, "RAGO_CSTATES=\"shallow\"\n");
        e.cstates = Some(CStates::Deep);
        let r = a.apply(&e);
        let c = r.iter().find(|x| x.knob == "cstates").unwrap();
        assert!(c.detail.contains("base M1 reste plus stricte"), "{c:?}");
        assert_eq!(a.system().m1_cstates(), Some(CStates::Shallow));
        f.write(M1_CONF, "RAGO_CSTATES='poll'\nRAGO_CSTATES=deep\n");
        assert_eq!(a.system().m1_cstates(), Some(CStates::Deep));
        fs::remove_file(f.root().join(M1_CONF)).unwrap();
        assert_eq!(a.system().m1_cstates(), None);
    }

    #[test]
    fn mitigations_are_checked_never_changed() {
        let f = FakeRoot::new(&["performance"], "performance");
        let mut a = f.applier();
        let mut e = eff();
        e.mitigations = Some(Mitigations::Off);
        let r = a.apply(&e);
        let m = r.iter().find(|x| x.knob == "mitigations").unwrap();
        assert_eq!(m.status, S::Skipped);
        assert!(m.detail.contains("RAGO_MITIGATIONS=off"), "{m:?}");
        f.write(CMDLINE, "root=/dev/x mitigations=off quiet\n");
        assert_eq!(a.system().kernel_mitigations(), Mitigations::Off);
        let r = a.apply(&e);
        assert_eq!(status_of(&r, "mitigations"), S::Unchanged);
        e.mitigations = Some(Mitigations::On);
        let r = a.apply(&e);
        assert_eq!(status_of(&r, "mitigations"), S::Info);
        // « auto,nosmt » ou un « mitigations=off » passé à init : actives.
        f.write(CMDLINE, "mitigations=auto,nosmt quiet -- mitigations=off\n");
        assert_eq!(a.system().kernel_mitigations(), Mitigations::On);
        f.write(CMDLINE, "mitigations=off mitigations=auto\n");
        assert_eq!(a.system().kernel_mitigations(), Mitigations::On);
    }

    #[test]
    fn gpu_hook_pending_then_applied_then_restored() {
        let f = FakeRoot::new(&["performance"], "performance");
        let mut a = f.applier();
        let mut e = eff();
        e.gpu_clocks = GpuClocks {
            mode: GpuMode::Fixed,
            core_mhz: Some(1800),
            mem_mhz: None,
        };
        let r = a.apply(&e);
        let g = r.iter().find(|x| x.knob == "gpu_clocks").unwrap();
        assert_eq!(g.status, S::Pending, "{g:?}");
        assert!(g.detail.contains("M9"), "{g:?}");
        a.restore();

        let log = f.root().join("gpu.log");
        let hook = f.root().join("hooks/gpu-clocks");
        fs::write(
            &hook,
            format!(
                "#!/bin/sh\necho \"$1 ${{RAGO_GPU_CLOCKS_MODE:-}} ${{RAGO_GPU_CORE_MHZ:-}}\" >> {}\necho ok\n",
                log.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
        let r = a.apply(&e);
        assert_eq!(status_of(&r, "gpu_clocks"), S::Applied, "{r:?}");
        assert!(a.saved().unwrap().gpu_applied);
        let r = a.restore();
        assert_eq!(status_of(&r, "gpu_clocks"), S::Restored, "{r:?}");
        assert_eq!(
            fs::read_to_string(&log).unwrap(),
            "apply fixed 1800\nrestore  \n"
        );
    }

    #[test]
    fn recovery_after_a_crash_restores_the_base() {
        let f = FakeRoot::new(&["performance", "performance"], "performance powersave");
        {
            let mut a = f.applier();
            let mut e = eff();
            e.cpu_governor = Some("powersave".into());
            e.thp = Some(Thp::Always);
            a.apply(&e);
            // « Plantage » : l'applier disparaît sans restore().
            std::mem::forget(a);
        }
        assert_eq!(f.gov(1), "powersave");
        let mut b = f.applier();
        let r = b.recover();
        assert_eq!(r[0].knob, "reprise");
        assert_eq!(f.gov(0), "performance");
        assert_eq!(f.gov(1), "performance");
        assert_eq!(f.thp(), "madvise");
        assert!(!f.root().join("run/applied.json").exists());
        // Rien à reprendre la fois suivante.
        assert!(f.applier().recover().is_empty());
        // Fichier d'état corrompu : supprimé, signalé, sans panique.
        f.write("run/applied.json", "{pas du json");
        let r = f.applier().recover();
        assert_eq!(r[0].status, S::Error);
        assert!(!f.root().join("run/applied.json").exists());
    }

    #[test]
    fn machine_without_cpufreq_or_thp() {
        let f = FakeRoot::new(&[], "");
        fs::remove_file(f.root().join(THP)).unwrap();
        let mut a = f.applier();
        let mut e = eff();
        e.cpu_governor = Some("performance".into());
        e.thp = Some(Thp::Always);
        let r = a.apply(&e);
        assert_eq!(status_of(&r, "cpu_governor"), S::Skipped);
        assert_eq!(status_of(&r, "thp"), S::Skipped);
        a.restore();
    }
}
