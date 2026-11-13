// SPDX-License-Identifier: GPL-2.0
//
// Profils par jeu : format (TOML ou JSON), validation, base de profils et
// résolution « jeu -> profil effectif », avec un profil sûr par défaut.
//
// Un profil décrit, pour un jeu, la surcharge à appliquer PAR-DESSUS le
// réglage de base de la machine (M1, profil tuned rago-gaming). Un champ
// absent veut dire « garder la base » : un profil ne contient que ce qui
// change pour ce jeu. Le format est décrit dans profiles/README.md et
// profiles/schema/rago-profile.schema.json.

use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

/// Version du format de profil comprise par ce démon.
pub const SCHEMA_VERSION: u32 = 1;

/// Identifiant réservé du profil sûr par défaut (impossible dans un fichier :
/// un id de fichier commence par une lettre ou un chiffre).
pub const FALLBACK_ID: &str = "_fallback";

/// Taille max d'un fichier de profil.
pub const MAX_FILE_SIZE: u64 = 64 * 1024;

/// Longueur max d'un motif de nom de thread (TASK_COMM_LEN - 1, comme M0).
pub const COMM_MAX: usize = 15;

/// Motifs de rendu ajoutables par un profil. scx_rago en accepte 16 au total
/// et en a déjà 8 par défaut (rago_common::DEFAULT_RENDER_COMMS).
pub const MAX_RENDER_COMMS: usize = 8;

/// Dossiers de profils par défaut, du plus prioritaire au moins prioritaire :
/// réglages locaux de la machine, puis base communautaire livrée avec Rago.
pub const DEFAULT_PROFILE_DIRS: &[&str] = &["/etc/rago/profiles", "/usr/share/rago/profiles"];

// --- valeurs ------------------------------------------------------------------------------

/// Couche sur laquelle le jeu tourne (voir docs/vault/Architecture).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Couche {
    /// Jeu natif sous Linux (Proton ou binaire Linux).
    Proton,
    /// Jeu lancé par le Fast OS Switch dans le micro-Windows (M5/M6).
    Switch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Thp {
    Madvise,
    Always,
}

/// Même vocabulaire que `--cstates` de M1 (host/setup_host_tuning.sh).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CStates {
    /// Aucune limite ajoutée.
    Deep,
    /// C1 au plus profond (comme latency-performance).
    Shallow,
    /// Aucun C-state (latence minimale, chauffe).
    Poll,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mitigations {
    On,
    Off,
}

/// Profil de sécurité du micro-Windows (appliqué par M5).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WindowsSecurity {
    /// VBS / HVCI / IOMMU activés (Vanguard, Ricochet...). Le défaut sûr.
    CompatMax,
    /// VBS / HVCI coupés (EAC, BattlEye...) : quelques FPS de plus.
    Perf,
}

/// Affinité du jeu, comme `rago-sched-hint run --confine`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Confine {
    #[default]
    Auto,
    On,
    Off,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GpuMode {
    /// Pas de surcharge : le pilote (ou le réglage de base de M9) décide.
    #[default]
    Auto,
    /// Horloges hautes verrouillées pendant le jeu.
    Max,
    /// Horloges fixes (core_mhz / mem_mhz).
    Fixed,
}

macro_rules! impl_display {
    ($t:ty, $( $v:path => $s:literal ),+ $(,)?) => {
        impl $t {
            pub fn as_str(&self) -> &'static str {
                match self { $( $v => $s ),+ }
            }
        }
        impl fmt::Display for $t {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(self.as_str())
            }
        }
    };
}

impl_display!(Couche, Couche::Proton => "proton", Couche::Switch => "switch");
impl_display!(Thp, Thp::Madvise => "madvise", Thp::Always => "always");
impl_display!(CStates, CStates::Deep => "deep", CStates::Shallow => "shallow", CStates::Poll => "poll");
impl_display!(Mitigations, Mitigations::On => "on", Mitigations::Off => "off");
impl_display!(WindowsSecurity, WindowsSecurity::CompatMax => "compat_max", WindowsSecurity::Perf => "perf");
impl_display!(Confine, Confine::Auto => "auto", Confine::On => "on", Confine::Off => "off");
impl_display!(GpuMode, GpuMode::Auto => "auto", GpuMode::Max => "max", GpuMode::Fixed => "fixed");

impl CStates {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "deep" => Some(Self::Deep),
            "shallow" => Some(Self::Shallow),
            "poll" => Some(Self::Poll),
            _ => None,
        }
    }
}

// --- fichier de profil ----------------------------------------------------------------------

/// Comment reconnaître le jeu quand le launcher ne donne pas l'id Rago.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Match {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steam_appid: Vec<u32>,
    /// Noms d'exécutable (sans chemin), comparés sans tenir compte de la casse.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub exe: Vec<String>,
}

fn yes() -> bool {
    true
}

/// Hint vers l'ordonnanceur scx_rago (M0), passé à `rago-sched-hint run`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SchedHint {
    /// false : le jeu n'est pas tagué (lancé tel quel).
    #[serde(default = "yes")]
    pub enabled: bool,
    #[serde(default)]
    pub confine: Confine,
    /// Préfixes de noms de threads de rendu propres à ce jeu (en plus des
    /// motifs par défaut de scx_rago).
    #[serde(default)]
    pub render_comm: Vec<String>,
}

impl Default for SchedHint {
    fn default() -> Self {
        Self {
            enabled: true,
            confine: Confine::Auto,
            render_comm: Vec::new(),
        }
    }
}

/// Horloges GPU (appliquées par M9 via le hook `gpu-clocks`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GpuClocks {
    #[serde(default)]
    pub mode: GpuMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub core_mhz: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mem_mhz: Option<u32>,
}

/// Un profil tel qu'écrit dans un fichier `<id>.toml` ou `<id>.json`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Profile {
    pub schema: u32,
    pub id: String,
    pub name: String,
    pub couche: Couche,
    #[serde(default, rename = "match")]
    pub matching: Match,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu_governor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thp: Option<Thp>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cstates: Option<CStates>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sched_hint: Option<SchedHint>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpu_clocks: Option<GpuClocks>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mitigations: Option<Mitigations>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub windows_security: Option<WindowsSecurity>,
    /// Anti-triche du jeu (information, non utilisée par le démon).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anticheat: Option<String>,
    /// true seulement après un vrai test sur matériel.
    #[serde(default)]
    pub verified: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
}

/// Résultat de validation : erreurs (profil refusé) et avertissements.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Findings {
    pub errors: Vec<String>,
    pub warnings: Vec<String>,
}

pub fn valid_id(id: &str) -> bool {
    let b = id.as_bytes();
    !b.is_empty()
        && b.len() <= 64
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

/// Nom de gouverneur cpufreq (CPUFREQ_NAME_LEN = 16).
pub fn valid_governor(g: &str) -> bool {
    !g.is_empty()
        && g.len() <= 15
        && g.bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
}

/// Même règle que rago_common::proto::valid_comm_pattern (M0).
pub fn valid_comm_pattern(p: &str) -> bool {
    !p.is_empty() && p.len() <= COMM_MAX && p.bytes().all(|b| b.is_ascii_graphic())
}

fn valid_exe(e: &str) -> bool {
    !e.is_empty()
        && e.len() <= 255
        && !e.contains('/')
        && !e.contains('\\')
        && !e.chars().any(char::is_control)
}

fn valid_text(s: &str, max: usize) -> bool {
    s.chars().count() <= max && !s.chars().any(|c| c.is_control() && c != '\n' && c != '\t')
}

/// Nom d'exécutable sans chemin (séparateurs Linux et Windows), en minuscules.
pub fn exe_key(path: &str) -> String {
    let base = path.rsplit(['/', '\\']).next().unwrap_or(path);
    base.to_lowercase()
}

impl Profile {
    /// Valide un profil. `stem` : nom du fichier sans extension (doit égaler l'id).
    pub fn validate(&self, stem: Option<&str>) -> Findings {
        let mut f = Findings::default();
        let e = &mut f.errors;
        if self.schema != SCHEMA_VERSION {
            e.push(format!(
                "schema = {} non pris en charge (ce démon lit la version {SCHEMA_VERSION})",
                self.schema
            ));
        }
        if !valid_id(&self.id) {
            e.push(format!(
                "id « {} » invalide : 1 à 64 caractères a-z, 0-9 et -, commençant par une lettre ou un chiffre",
                self.id
            ));
        }
        if let Some(s) = stem
            && s != self.id
        {
            e.push(format!(
                "id « {} » différent du nom du fichier « {s} »",
                self.id
            ));
        }
        if self.name.trim().is_empty() || !valid_text(&self.name, 120) {
            e.push("name vide, trop long (120 max) ou avec des caractères de contrôle".into());
        }
        for a in &self.matching.steam_appid {
            if *a == 0 {
                e.push("match.steam_appid : 0 interdit".into());
            }
        }
        for x in &self.matching.exe {
            if !valid_exe(x) {
                e.push(format!(
                    "match.exe « {x} » invalide (nom de fichier seul, sans / ni \\)"
                ));
            }
        }
        if let Some(g) = &self.cpu_governor
            && !valid_governor(g)
        {
            e.push(format!(
                "cpu_governor « {g} » invalide (a-z, 0-9, _ ; 15 max)"
            ));
        }
        if let Some(h) = &self.sched_hint {
            if h.render_comm.len() > MAX_RENDER_COMMS {
                e.push(format!(
                    "sched_hint.render_comm : {} motifs, {MAX_RENDER_COMMS} max",
                    h.render_comm.len()
                ));
            }
            for p in &h.render_comm {
                if !valid_comm_pattern(p) {
                    e.push(format!(
                        "sched_hint.render_comm « {p} » invalide (1 à {COMM_MAX} caractères ASCII sans espace)"
                    ));
                }
            }
        }
        if let Some(g) = &self.gpu_clocks {
            match g.mode {
                GpuMode::Fixed => {
                    if g.core_mhz.is_none() && g.mem_mhz.is_none() {
                        e.push("gpu_clocks.mode = fixed demande core_mhz et/ou mem_mhz".into());
                    }
                    if let Some(c) = g.core_mhz
                        && !(100..=5000).contains(&c)
                    {
                        e.push(format!("gpu_clocks.core_mhz = {c} hors de 100..5000"));
                    }
                    if let Some(m) = g.mem_mhz
                        && !(100..=40000).contains(&m)
                    {
                        e.push(format!("gpu_clocks.mem_mhz = {m} hors de 100..40000"));
                    }
                }
                GpuMode::Auto | GpuMode::Max => {
                    if g.core_mhz.is_some() || g.mem_mhz.is_some() {
                        e.push(format!(
                            "gpu_clocks : core_mhz / mem_mhz seulement avec mode = fixed (ici {})",
                            g.mode
                        ));
                    }
                }
            }
        }
        if let Some(a) = &self.anticheat
            && !valid_text(a, 64)
        {
            e.push("anticheat trop long (64 max)".into());
        }
        if let Some(n) = &self.notes
            && !valid_text(n, 2000)
        {
            e.push("notes trop longues (2000 max)".into());
        }

        let w = &mut f.warnings;
        let mut dup = std::collections::BTreeSet::new();
        for a in &self.matching.steam_appid {
            if !dup.insert(a.to_string()) {
                w.push(format!("match.steam_appid {a} en double"));
            }
        }
        dup.clear();
        for x in &self.matching.exe {
            if !dup.insert(x.to_lowercase()) {
                w.push(format!("match.exe « {x} » en double"));
            }
        }
        match self.couche {
            Couche::Switch => {
                let linux: Vec<&str> = [
                    ("cpu_governor", self.cpu_governor.is_some()),
                    ("thp", self.thp.is_some()),
                    ("cstates", self.cstates.is_some()),
                    ("sched_hint", self.sched_hint.is_some()),
                    ("gpu_clocks", self.gpu_clocks.is_some()),
                    ("mitigations", self.mitigations.is_some()),
                ]
                .iter()
                .filter(|(_, set)| *set)
                .map(|(k, _)| *k)
                .collect();
                if !linux.is_empty() {
                    w.push(format!(
                        "couche switch : {} ignoré(s) (le jeu tourne sous le micro-Windows)",
                        linux.join(", ")
                    ));
                }
                if self.windows_security.is_none() {
                    w.push(
                        "couche switch sans windows_security : compat_max (sûr) sera utilisé"
                            .into(),
                    );
                }
            }
            Couche::Proton => {
                if self.windows_security.is_some() {
                    w.push(
                        "couche proton : windows_security ignoré (sert seulement au switch)".into(),
                    );
                }
            }
        }
        if self.matching.steam_appid.is_empty() && self.matching.exe.is_empty() {
            w.push("aucun critère match : ce profil ne sera trouvé que par son id".into());
        }
        f
    }
}

/// Lit et valide un fichier de profil (`.toml` ou `.json`).
pub fn parse_file(path: &Path) -> Result<(Profile, Vec<String>), String> {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
    let stem = path.file_stem().and_then(|s| s.to_str());
    let meta = fs::metadata(path).map_err(|e| format!("illisible : {e}"))?;
    if !meta.is_file() {
        return Err("pas un fichier ordinaire".into());
    }
    if meta.len() > MAX_FILE_SIZE {
        return Err(format!(
            "trop gros ({} octets, {MAX_FILE_SIZE} max)",
            meta.len()
        ));
    }
    let text = fs::read_to_string(path).map_err(|e| format!("illisible : {e}"))?;
    let p: Profile = match ext {
        "toml" => toml::from_str(&text).map_err(|e| format!("TOML invalide : {}", e.message()))?,
        "json" => serde_json::from_str(&text).map_err(|e| format!("JSON invalide : {e}"))?,
        _ => return Err(format!("extension « {ext} » inconnue (.toml ou .json)")),
    };
    let f = p.validate(stem);
    if !f.errors.is_empty() {
        return Err(f.errors.join(" ; "));
    }
    Ok((p, f.warnings))
}

/// Fichier candidat d'un dossier de profils : `.toml` ou `.json`, non caché.
fn is_profile_file(p: &Path) -> bool {
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
    !name.starts_with('.')
        && matches!(
            p.extension().and_then(|e| e.to_str()),
            Some("toml" | "json")
        )
}

// --- profil effectif ------------------------------------------------------------------------

/// Ce que le launcher demande : tout est optionnel.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Query {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub steam_appid: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exe: Option<String>,
    /// Couche voulue si aucun profil n'est trouvé.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub couche: Option<Couche>,
}

impl Query {
    pub fn describe(&self) -> String {
        let mut v = Vec::new();
        if let Some(i) = &self.id {
            v.push(format!("id={i}"));
        }
        if let Some(a) = self.steam_appid {
            v.push(format!("steam_appid={a}"));
        }
        if let Some(x) = &self.exe {
            v.push(format!("exe={x}"));
        }
        if v.is_empty() {
            "aucun critère".into()
        } else {
            v.join(" ")
        }
    }
}

/// Profil prêt à appliquer : valeurs par défaut sûres remplies, champs sans
/// effet sur la couche retirés.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Effective {
    pub id: String,
    pub name: String,
    pub couche: Couche,
    /// Fichier d'origine, ou « intégré ».
    pub source: String,
    /// Critère qui a trouvé le profil (id, steam_appid, exe).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub matched_by: Option<String>,
    /// Raison du repli sur le profil sûr, s'il y a repli.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu_governor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thp: Option<Thp>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cstates: Option<CStates>,
    pub sched_hint: SchedHint,
    pub gpu_clocks: GpuClocks,
    /// None : le profil ne demande rien (le noyau garde son réglage).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mitigations: Option<Mitigations>,
    pub windows_security: WindowsSecurity,
    pub verified: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
}

impl Effective {
    /// Le profil sûr par défaut : ne change RIEN au réglage de base (M1),
    /// garde le hint ordonnanceur de M0 (comportement normal), et côté switch
    /// garde toute la sécurité Windows (compat_max).
    pub fn fallback(couche: Couche, reason: String) -> Self {
        Self {
            id: FALLBACK_ID.into(),
            name: "Profil sûr par défaut".into(),
            couche,
            source: "intégré".into(),
            matched_by: None,
            fallback: Some(reason),
            cpu_governor: None,
            thp: None,
            cstates: None,
            sched_hint: SchedHint::default(),
            gpu_clocks: GpuClocks::default(),
            mitigations: None,
            windows_security: WindowsSecurity::CompatMax,
            verified: true,
            warnings: Vec::new(),
        }
    }

    pub fn from_profile(p: &Profile, source: &Path, matched_by: &str, warnings: &[String]) -> Self {
        let mut e = Self {
            id: p.id.clone(),
            name: p.name.clone(),
            couche: p.couche,
            source: source.display().to_string(),
            matched_by: Some(matched_by.into()),
            fallback: None,
            cpu_governor: p.cpu_governor.clone(),
            thp: p.thp,
            cstates: p.cstates,
            sched_hint: p.sched_hint.clone().unwrap_or_default(),
            gpu_clocks: p.gpu_clocks.clone().unwrap_or_default(),
            mitigations: p.mitigations,
            windows_security: p.windows_security.unwrap_or(WindowsSecurity::CompatMax),
            verified: p.verified,
            warnings: warnings.to_vec(),
        };
        if e.couche == Couche::Switch {
            // Le jeu tourne sous Windows : rien à régler côté Linux.
            e.cpu_governor = None;
            e.thp = None;
            e.cstates = None;
            e.gpu_clocks = GpuClocks::default();
            e.mitigations = None;
        }
        e
    }

    pub fn is_fallback(&self) -> bool {
        self.fallback.is_some()
    }
}

// --- base de profils ------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct Entry {
    pub profile: Profile,
    pub path: PathBuf,
    /// Rang du dossier (0 = le plus prioritaire).
    pub rank: usize,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LoadError {
    pub path: PathBuf,
    pub message: String,
}

/// Empreinte d'un dossier : (fichier, date de modification, taille).
type Fingerprint = Vec<(PathBuf, Option<SystemTime>, u64)>;

#[derive(Clone, Debug, Default)]
pub struct Store {
    dirs: Vec<PathBuf>,
    by_id: BTreeMap<String, Entry>,
    by_appid: BTreeMap<u32, String>,
    by_exe: BTreeMap<String, String>,
    /// Profils refusés, par nom de fichier sans extension.
    invalid: BTreeMap<String, String>,
    pub errors: Vec<LoadError>,
    /// Remplacements et conflits de critères (informations).
    pub notes: Vec<String>,
    fingerprint: Fingerprint,
}

fn fingerprint(dirs: &[PathBuf]) -> Fingerprint {
    let mut out = Vec::new();
    for d in dirs {
        let Ok(rd) = fs::read_dir(d) else {
            out.push((d.clone(), None, 0));
            continue;
        };
        let mut v: Vec<_> = rd
            .flatten()
            .map(|e| e.path())
            .filter(|p| is_profile_file(p))
            .map(|p| {
                let m = fs::metadata(&p).ok();
                let t = m.as_ref().and_then(|m| m.modified().ok());
                let l = m.map(|m| m.len()).unwrap_or(0);
                (p, t, l)
            })
            .collect();
        v.sort();
        out.push((d.clone(), None, v.len() as u64));
        out.extend(v);
    }
    out
}

impl Store {
    /// Charge les dossiers, du plus prioritaire au moins prioritaire. Un
    /// dossier absent n'est pas une erreur. Ne panique jamais : un fichier
    /// cassé est noté dans `errors` et ignoré.
    pub fn load(dirs: &[PathBuf]) -> Self {
        let mut s = Store {
            dirs: dirs.to_vec(),
            fingerprint: fingerprint(dirs),
            ..Default::default()
        };
        for (rank, dir) in dirs.iter().enumerate() {
            let rd = match fs::read_dir(dir) {
                Ok(rd) => rd,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => {
                    s.errors.push(LoadError {
                        path: dir.clone(),
                        message: format!("dossier illisible : {e}"),
                    });
                    continue;
                }
            };
            let mut files: Vec<PathBuf> = rd
                .flatten()
                .map(|e| e.path())
                .filter(|p| is_profile_file(p))
                .collect();
            files.sort();
            for path in files {
                let stem = path
                    .file_stem()
                    .and_then(|x| x.to_str())
                    .unwrap_or("")
                    .to_string();
                match parse_file(&path) {
                    Ok((profile, warnings)) => {
                        if let Some(prev) = s.by_id.get(&profile.id) {
                            if prev.rank < rank {
                                s.notes.push(format!(
                                    "{} : remplacé par {}",
                                    path.display(),
                                    prev.path.display()
                                ));
                            } else {
                                s.errors.push(LoadError {
                                    path: path.clone(),
                                    message: format!(
                                        "id « {} » déjà défini par {}",
                                        profile.id,
                                        prev.path.display()
                                    ),
                                });
                            }
                            continue;
                        }
                        s.by_id.insert(
                            profile.id.clone(),
                            Entry {
                                profile,
                                path,
                                rank,
                                warnings,
                            },
                        );
                    }
                    Err(msg) => {
                        s.invalid.entry(stem).or_insert_with(|| msg.clone());
                        s.errors.push(LoadError { path, message: msg });
                    }
                }
            }
        }
        s.build_index();
        s
    }

    /// Index des critères match, une fois les remplacements faits : le
    /// premier qui revendique un critère gagne (dossier prioritaire, puis
    /// ordre alphabétique des id).
    fn build_index(&mut self) {
        let mut entries: Vec<&Entry> = self.by_id.values().collect();
        entries.sort_by(|a, b| (a.rank, &a.profile.id).cmp(&(b.rank, &b.profile.id)));
        let mut notes = Vec::new();
        for e in entries {
            for a in &e.profile.matching.steam_appid {
                match self.by_appid.get(a) {
                    Some(other) if other != &e.profile.id => notes.push(format!(
                        "steam_appid {a} revendiqué par « {other} » et « {} » : « {other} » gagne",
                        e.profile.id
                    )),
                    Some(_) => {}
                    None => {
                        self.by_appid.insert(*a, e.profile.id.clone());
                    }
                }
            }
            for x in &e.profile.matching.exe {
                let k = x.to_lowercase();
                match self.by_exe.get(&k) {
                    Some(other) if other != &e.profile.id => notes.push(format!(
                        "exe « {x} » revendiqué par « {other} » et « {} » : « {other} » gagne",
                        e.profile.id
                    )),
                    Some(_) => {}
                    None => {
                        self.by_exe.insert(k, e.profile.id.clone());
                    }
                }
            }
        }
        self.notes.extend(notes);
    }

    /// Recharge si un fichier a changé (ajout, suppression, modification).
    pub fn refresh(&mut self) -> bool {
        if fingerprint(&self.dirs) == self.fingerprint {
            return false;
        }
        *self = Store::load(&self.dirs.clone());
        true
    }

    pub fn dirs(&self) -> &[PathBuf] {
        &self.dirs
    }

    pub fn entries(&self) -> impl Iterator<Item = &Entry> {
        self.by_id.values()
    }

    #[cfg(test)]
    pub fn get(&self, id: &str) -> Option<&Entry> {
        self.by_id.get(id)
    }

    /// Jeu -> profil effectif. Ordre : id, puis steam_appid, puis exe ; sinon
    /// le profil sûr par défaut, avec la raison.
    pub fn resolve(&self, q: &Query) -> Effective {
        let found =
            q.id.as_ref()
                .and_then(|i| self.by_id.get(i).map(|e| (e, "id")))
                .or_else(|| {
                    q.steam_appid
                        .and_then(|a| self.by_appid.get(&a))
                        .and_then(|i| self.by_id.get(i))
                        .map(|e| (e, "steam_appid"))
                })
                .or_else(|| {
                    q.exe
                        .as_ref()
                        .and_then(|x| self.by_exe.get(&exe_key(x)))
                        .and_then(|i| self.by_id.get(i))
                        .map(|e| (e, "exe"))
                });
        if let Some((e, how)) = found {
            return Effective::from_profile(&e.profile, &e.path, how, &e.warnings);
        }
        let couche = q.couche.unwrap_or(Couche::Proton);
        let reason = match q.id.as_ref().and_then(|i| self.invalid.get(i)) {
            Some(err) => format!(
                "profil « {} » refusé ({err}) : profil sûr par défaut",
                q.id.as_deref().unwrap_or("")
            ),
            None => format!("aucun profil pour {} : profil sûr par défaut", q.describe()),
        };
        Effective::fallback(couche, reason)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, name: &str, body: &str) -> PathBuf {
        let p = dir.join(name);
        fs::write(&p, body).unwrap();
        p
    }

    const CP: &str = r#"
schema = 1
id = "cyberpunk-2077"
name = "Cyberpunk 2077"
couche = "proton"
cpu_governor = "performance"
thp = "always"
cstates = "shallow"
mitigations = "on"
[match]
steam_appid = [1091500]
exe = ["Cyberpunk2077.exe"]
[sched_hint]
confine = "auto"
render_comm = ["RenderThread"]
[gpu_clocks]
mode = "max"
"#;

    #[test]
    fn toml_profile_parses_and_resolves_by_each_key() {
        let d = tempfile::tempdir().unwrap();
        write(d.path(), "cyberpunk-2077.toml", CP);
        let s = Store::load(&[d.path().to_path_buf()]);
        assert!(s.errors.is_empty(), "{:?}", s.errors);
        let by_id = s.resolve(&Query {
            id: Some("cyberpunk-2077".into()),
            ..Default::default()
        });
        assert_eq!(by_id.matched_by.as_deref(), Some("id"));
        assert_eq!(by_id.thp, Some(Thp::Always));
        assert_eq!(by_id.cstates, Some(CStates::Shallow));
        assert_eq!(by_id.gpu_clocks.mode, GpuMode::Max);
        assert_eq!(
            by_id.sched_hint.render_comm,
            vec!["RenderThread".to_string()]
        );
        let by_app = s.resolve(&Query {
            steam_appid: Some(1091500),
            ..Default::default()
        });
        assert_eq!(by_app.id, "cyberpunk-2077");
        assert_eq!(by_app.matched_by.as_deref(), Some("steam_appid"));
        // Chemin Windows et casse différente.
        let by_exe = s.resolve(&Query {
            exe: Some(r"C:\Games\Cyberpunk 2077\bin\x64\CYBERPUNK2077.EXE".into()),
            ..Default::default()
        });
        assert_eq!(by_exe.id, "cyberpunk-2077");
        assert_eq!(by_exe.matched_by.as_deref(), Some("exe"));
    }

    #[test]
    fn json_profile_is_equivalent() {
        let d = tempfile::tempdir().unwrap();
        write(
            d.path(),
            "elden-ring.json",
            r#"{"schema":1,"id":"elden-ring","name":"Elden Ring","couche":"proton",
                "match":{"steam_appid":[1245620]},"thp":"madvise","cstates":"deep"}"#,
        );
        let s = Store::load(&[d.path().to_path_buf()]);
        assert!(s.errors.is_empty(), "{:?}", s.errors);
        let e = s.resolve(&Query {
            steam_appid: Some(1245620),
            ..Default::default()
        });
        assert_eq!(e.id, "elden-ring");
        assert_eq!(e.thp, Some(Thp::Madvise));
        assert_eq!(e.cpu_governor, None);
        assert!(e.sched_hint.enabled);
        assert_eq!(e.windows_security, WindowsSecurity::CompatMax);
    }

    #[test]
    fn unknown_game_gets_safe_fallback() {
        let d = tempfile::tempdir().unwrap();
        let s = Store::load(&[d.path().to_path_buf(), d.path().join("absent")]);
        let e = s.resolve(&Query {
            id: Some("jeu-inconnu".into()),
            exe: Some("Inconnu.exe".into()),
            ..Default::default()
        });
        assert!(e.is_fallback());
        assert_eq!(e.id, FALLBACK_ID);
        assert_eq!(e.couche, Couche::Proton);
        assert_eq!(e.cpu_governor, None);
        assert_eq!(e.thp, None);
        assert_eq!(e.cstates, None);
        assert_eq!(e.mitigations, None);
        assert_eq!(e.gpu_clocks.mode, GpuMode::Auto);
        assert!(e.sched_hint.enabled);
        assert_eq!(e.sched_hint.confine, Confine::Auto);
        assert_eq!(e.windows_security, WindowsSecurity::CompatMax);
        assert!(e.fallback.unwrap().contains("id=jeu-inconnu"));
        // Couche demandée par le launcher pour un jeu inconnu.
        let sw = s.resolve(&Query {
            couche: Some(Couche::Switch),
            ..Default::default()
        });
        assert_eq!(sw.couche, Couche::Switch);
        assert_eq!(sw.windows_security, WindowsSecurity::CompatMax);
    }

    #[test]
    fn broken_profile_falls_back_with_reason_and_never_panics() {
        let d = tempfile::tempdir().unwrap();
        write(
            d.path(),
            "casse.toml",
            "schema = 1\nid = \"casse\"\nname = \"x\"\ncouche = \"proton\"\nthp = \"never\"\n",
        );
        write(d.path(), "pas-du-toml.toml", "{{{{ ceci n'est pas du TOML");
        write(
            d.path(),
            "mauvais-nom.toml",
            "schema = 1\nid = \"autre-id\"\nname = \"x\"\ncouche = \"proton\"\n",
        );
        write(
            d.path(),
            "inconnu.toml",
            "schema = 1\nid = \"inconnu\"\nname = \"x\"\ncouche = \"proton\"\nturbo = true\n",
        );
        write(
            d.path(),
            "futur.toml",
            "schema = 2\nid = \"futur\"\nname = \"x\"\ncouche = \"proton\"\n",
        );
        write(d.path(), "ignore.txt", "pas un profil");
        write(d.path(), ".cache.toml", "caché");
        let s = Store::load(&[d.path().to_path_buf()]);
        assert_eq!(s.errors.len(), 5, "{:?}", s.errors);
        assert_eq!(s.entries().count(), 0);
        let e = s.resolve(&Query {
            id: Some("casse".into()),
            ..Default::default()
        });
        assert!(e.is_fallback());
        assert!(
            e.fallback.as_ref().unwrap().contains("refusé"),
            "{:?}",
            e.fallback
        );
    }

    #[test]
    fn local_dir_overrides_community_and_match_keys_do_not_leak() {
        let etc = tempfile::tempdir().unwrap();
        let usr = tempfile::tempdir().unwrap();
        write(usr.path(), "cyberpunk-2077.toml", CP);
        write(
            etc.path(),
            "cyberpunk-2077.json",
            r#"{"schema":1,"id":"cyberpunk-2077","name":"CP local","couche":"proton","thp":"madvise",
                "match":{"exe":["cp-local.exe"]}}"#,
        );
        let s = Store::load(&[etc.path().to_path_buf(), usr.path().to_path_buf()]);
        assert!(s.errors.is_empty(), "{:?}", s.errors);
        assert_eq!(s.notes.len(), 1, "{:?}", s.notes);
        let e = s.resolve(&Query {
            id: Some("cyberpunk-2077".into()),
            ..Default::default()
        });
        assert_eq!(e.name, "CP local");
        assert_eq!(e.thp, Some(Thp::Madvise));
        // Les critères du profil communautaire remplacé ne comptent plus.
        let old = s.resolve(&Query {
            steam_appid: Some(1091500),
            ..Default::default()
        });
        assert!(old.is_fallback());
    }

    #[test]
    fn duplicates_in_same_dir_and_key_conflicts() {
        let d = tempfile::tempdir().unwrap();
        write(
            d.path(),
            "a.toml",
            "schema = 1\nid = \"a\"\nname = \"A\"\ncouche = \"proton\"\n[match]\nsteam_appid = [42]\n",
        );
        write(
            d.path(),
            "a.json",
            r#"{"schema":1,"id":"a","name":"A json","couche":"proton"}"#,
        );
        write(
            d.path(),
            "b.toml",
            "schema = 1\nid = \"b\"\nname = \"B\"\ncouche = \"proton\"\n[match]\nsteam_appid = [42]\n",
        );
        let s = Store::load(&[d.path().to_path_buf()]);
        // a.json est lu en premier (ordre alphabétique) ; a.toml est refusé.
        assert_eq!(s.errors.len(), 1, "{:?}", s.errors);
        assert!(s.errors[0].path.ends_with("a.toml"));
        assert_eq!(s.get("a").unwrap().profile.name, "A json");
        let e = s.resolve(&Query {
            steam_appid: Some(42),
            ..Default::default()
        });
        assert_eq!(e.id, "b", "a.json ne revendique pas 42 : b le garde");
    }

    #[test]
    fn switch_profile_drops_linux_fields_and_warns() {
        let p: Profile = toml::from_str(
            "schema = 1\nid = \"valorant\"\nname = \"Valorant\"\ncouche = \"switch\"\nthp = \"always\"\n",
        )
        .unwrap();
        let f = p.validate(Some("valorant"));
        assert!(f.errors.is_empty());
        assert!(
            f.warnings.iter().any(|w| w.contains("thp")),
            "{:?}",
            f.warnings
        );
        assert!(
            f.warnings.iter().any(|w| w.contains("compat_max")),
            "{:?}",
            f.warnings
        );
        let e = Effective::from_profile(&p, Path::new("/x/valorant.toml"), "id", &f.warnings);
        assert_eq!(e.thp, None);
        assert_eq!(e.windows_security, WindowsSecurity::CompatMax);
    }

    #[test]
    fn validation_rules() {
        let base = |extra: &str| -> Findings {
            let p: Profile = toml::from_str(&format!(
                "schema = 1\nid = \"x\"\nname = \"X\"\ncouche = \"proton\"\n{extra}"
            ))
            .unwrap();
            p.validate(Some("x"))
        };
        assert!(base("").errors.is_empty());
        assert!(!base("cpu_governor = \"Performance\"\n").errors.is_empty());
        assert!(
            !base("cpu_governor = \"a_very_long_governor\"\n")
                .errors
                .is_empty()
        );
        assert!(!base("[gpu_clocks]\nmode = \"fixed\"\n").errors.is_empty());
        assert!(
            !base("[gpu_clocks]\nmode = \"max\"\ncore_mhz = 2000\n")
                .errors
                .is_empty()
        );
        assert!(
            !base("[gpu_clocks]\nmode = \"fixed\"\ncore_mhz = 99999\n")
                .errors
                .is_empty()
        );
        assert!(
            base("[gpu_clocks]\nmode = \"fixed\"\ncore_mhz = 1800\nmem_mhz = 7000\n")
                .errors
                .is_empty()
        );
        assert!(
            !base("[sched_hint]\nrender_comm = [\"avec espace\"]\n")
                .errors
                .is_empty()
        );
        assert!(
            !base("[sched_hint]\nrender_comm = [\"motif-beaucoup-trop-long\"]\n")
                .errors
                .is_empty()
        );
        assert!(
            !base("[sched_hint]\nrender_comm = [\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\"]\n")
                .errors
                .is_empty()
        );
        assert!(!base("[match]\nsteam_appid = [0]\n").errors.is_empty());
        assert!(!base("[match]\nexe = [\"bin/jeu.exe\"]\n").errors.is_empty());
        assert!(!base("windows_security = \"perf\"\n").warnings.is_empty());
        let p: Profile =
            toml::from_str("schema = 1\nid = \"Majuscule\"\nname = \"X\"\ncouche = \"proton\"\n")
                .unwrap();
        assert!(!p.validate(None).errors.is_empty());
        let p: Profile =
            toml::from_str("schema = 1\nid = \"x\"\nname = \"  \"\ncouche = \"proton\"\n").unwrap();
        assert!(!p.validate(None).errors.is_empty());
        assert!(
            toml::from_str::<Profile>("schema = 1\nid = \"x\"\nname = \"X\"\ncouche = \"vm\"\n")
                .is_err()
        );
        assert!(toml::from_str::<Profile>("schema = 1\nid = \"x\"\nname = \"X\"\ncouche = \"proton\"\nmitigations = \"auto\"\n").is_err());
    }

    #[test]
    fn refresh_sees_new_and_removed_files() {
        let d = tempfile::tempdir().unwrap();
        let mut s = Store::load(&[d.path().to_path_buf()]);
        assert!(!s.refresh());
        let p = write(d.path(), "cyberpunk-2077.toml", CP);
        assert!(s.refresh());
        assert!(s.get("cyberpunk-2077").is_some());
        assert!(!s.refresh());
        fs::remove_file(p).unwrap();
        assert!(s.refresh());
        assert!(s.get("cyberpunk-2077").is_none());
    }

    #[test]
    fn exe_key_strips_paths() {
        assert_eq!(exe_key("/home/a/Jeu.EXE"), "jeu.exe");
        assert_eq!(exe_key(r"Z:\x\y\Game.exe"), "game.exe");
        assert_eq!(exe_key("cs2"), "cs2");
    }
}
