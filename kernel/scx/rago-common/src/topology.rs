// SPDX-License-Identifier: GPL-2.0
//
// Détection de la topologie CPU pour le routage du jeu.
//
//   - Intel hybride  : le noyau expose deux PMU, /sys/devices/cpu_core (P-cores)
//                      et /sys/devices/cpu_atom (E-cores). Jeu -> P, fond -> E.
//   - Ryzen X3D      : plusieurs domaines L3 (un par CCD) de tailles différentes
//                      (ex. 96 Mo vs 32 Mo sur 7950X3D/9950X3D). Jeu -> CCD au
//                      plus gros L3, fond -> autres CCD. Un X3D mono-CCD
//                      (7800X3D, 9800X3D) n'a qu'un L3 : symétrique.
//   - Capacités      : sinon, si cpu_capacity diffère de plus de 10 % entre CPU
//                      (big.LITTLE générique), jeu -> CPU de capacité max.
//   - Symétrique     : sinon, aucun routage (seul le boost de criticité agit).
//
// Toutes les lectures passent par `root` pour pouvoir tester sur un faux sysfs.

use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::cpuset::CpuSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TopologyKind {
    Symmetric,
    X3d,
    Hybrid,
}

impl TopologyKind {
    /// Valeur de enum rago_topo_kind (rago_intf.h).
    pub fn as_bpf(self) -> u32 {
        match self {
            TopologyKind::Symmetric => 0,
            TopologyKind::X3d => 1,
            TopologyKind::Hybrid => 2,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            TopologyKind::Symmetric => "symmetric",
            TopologyKind::X3d => "x3d",
            TopologyKind::Hybrid => "hybrid",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "symmetric" | "sym" | "none" => Some(TopologyKind::Symmetric),
            "x3d" => Some(TopologyKind::X3d),
            "hybrid" | "pe" | "p-e" => Some(TopologyKind::Hybrid),
            _ => None,
        }
    }
}

impl fmt::Display for TopologyKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Topology {
    pub kind: TopologyKind,
    /// CPU en ligne.
    pub online: CpuSet,
    /// CPU réservés au jeu (vide si symétrique).
    pub game: CpuSet,
    /// CPU préférés pour le fond pendant un jeu (vide si symétrique).
    pub bg: CpuSet,
    /// Explication lisible de la détection.
    pub detail: String,
}

impl Topology {
    /// Le jeu doit-il être confiné (affinité stricte) à `game` ?
    /// Oui sur X3D (le cache 3D ne profite qu'aux threads de son CCD).
    /// Non sur hybride : les threads secondaires peuvent déborder sur les
    /// E-cores ; seul le thread de rendu est gardé sur les P-cores (BPF).
    pub fn confine_by_default(&self) -> bool {
        self.kind == TopologyKind::X3d
    }

    /// Topologie imposée à la main (option --rago-topo / --rago-game-cpus).
    pub fn manual(
        kind: TopologyKind,
        online: CpuSet,
        game: CpuSet,
        bg: Option<CpuSet>,
    ) -> Result<Self, String> {
        if kind == TopologyKind::Symmetric {
            return Ok(Self::symmetric(online, "imposée : symétrique".into()));
        }
        if game.is_empty() {
            return Err("masque jeu vide".into());
        }
        if !game.is_subset(&online) {
            return Err(format!(
                "masque jeu {game} hors des CPU en ligne {online}"
            ));
        }
        let bg = bg.unwrap_or_else(|| online.difference(&game));
        if !bg.is_subset(&online) {
            return Err(format!("masque fond {bg} hors des CPU en ligne {online}"));
        }
        let detail = format!("imposée : {kind}, jeu {game}, fond {bg}");
        Ok(Self {
            kind,
            online,
            game,
            bg,
            detail,
        })
    }

    fn symmetric(online: CpuSet, detail: String) -> Self {
        Self {
            kind: TopologyKind::Symmetric,
            online,
            game: CpuSet::new(),
            bg: CpuSet::new(),
            detail,
        }
    }

    /// Détecte la topologie de la machine (`root` = "/" en production).
    pub fn detect(root: &Path) -> io::Result<Self> {
        let cpu_dir = root.join("sys/devices/system/cpu");
        let online = read_cpuset(&cpu_dir.join("online"))?;
        if online.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "aucun CPU en ligne dans sys/devices/system/cpu/online",
            ));
        }

        if let Some(t) = detect_hybrid(root, &online)? {
            return Ok(t);
        }
        if let Some(t) = detect_x3d(&cpu_dir, &online)? {
            return Ok(t);
        }
        if let Some(t) = detect_capacity(&cpu_dir, &online)? {
            return Ok(t);
        }
        let n = online.len();
        Ok(Self::symmetric(
            online,
            format!("{n} CPU équivalents : pas de routage, boost de criticité seul"),
        ))
    }
}

fn read_trim(path: &Path) -> io::Result<String> {
    Ok(fs::read_to_string(path)?.trim().to_string())
}

fn read_cpuset(path: &Path) -> io::Result<CpuSet> {
    let s = read_trim(path)?;
    CpuSet::parse(&s).map_err(|e| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{} : {e}", path.display()),
        )
    })
}

fn read_opt(path: &Path) -> io::Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(s) => Ok(Some(s.trim().to_string())),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

fn detect_hybrid(root: &Path, online: &CpuSet) -> io::Result<Option<Topology>> {
    let p = read_opt(&root.join("sys/devices/cpu_core/cpus"))?;
    let e = read_opt(&root.join("sys/devices/cpu_atom/cpus"))?;
    let (Some(p), Some(e)) = (p, e) else {
        return Ok(None);
    };
    let to_set = |s: &str| {
        CpuSet::parse(s).map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err.to_string()))
    };
    let p = to_set(&p)?.intersection(online);
    let e = to_set(&e)?.intersection(online);
    if p.is_empty() || e.is_empty() {
        return Ok(None);
    }
    let detail = format!("Intel hybride : P-cores {p} (jeu), E-cores {e} (fond)");
    Ok(Some(Topology {
        kind: TopologyKind::Hybrid,
        online: online.clone(),
        game: p,
        bg: e,
        detail,
    }))
}

/// Taille de cache sysfs (« 98304K », « 32M ») en Kio.
pub fn parse_cache_size(s: &str) -> Option<u64> {
    let s = s.trim();
    let (num, mul) = if let Some(n) = s.strip_suffix('K') {
        (n, 1)
    } else if let Some(n) = s.strip_suffix('M') {
        (n, 1024)
    } else if let Some(n) = s.strip_suffix('G') {
        (n, 1024 * 1024)
    } else {
        (s, 1)
    };
    num.trim().parse::<u64>().ok().map(|v| v * mul)
}

struct L3Domain {
    cpus: CpuSet,
    size_kib: u64,
}

fn l3_of_cpu(cpu_dir: &Path, cpu: u32) -> io::Result<Option<(String, u64)>> {
    let cache = cpu_dir.join(format!("cpu{cpu}/cache"));
    let entries = match fs::read_dir(&cache) {
        Ok(e) => e,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let mut idx: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("index"))
        })
        .collect();
    idx.sort();
    for dir in idx {
        if read_opt(&dir.join("level"))?.as_deref() != Some("3") {
            continue;
        }
        let shared = read_opt(&dir.join("shared_cpu_list"))?.unwrap_or_default();
        let size = read_opt(&dir.join("size"))?
            .and_then(|s| parse_cache_size(&s))
            .unwrap_or(0);
        return Ok(Some((shared, size)));
    }
    Ok(None)
}

fn detect_x3d(cpu_dir: &Path, online: &CpuSet) -> io::Result<Option<Topology>> {
    let mut domains: Vec<(String, L3Domain)> = Vec::new();
    for cpu in online.iter() {
        let Some((shared, size)) = l3_of_cpu(cpu_dir, cpu)? else {
            return Ok(None);
        };
        if let Some((_, d)) = domains.iter_mut().find(|(k, _)| *k == shared) {
            d.cpus.insert(cpu);
        } else {
            let mut cpus = CpuSet::new();
            cpus.insert(cpu);
            domains.push((shared, L3Domain { cpus, size_kib: size }));
        }
    }
    if domains.len() < 2 {
        return Ok(None);
    }
    let max = domains.iter().map(|(_, d)| d.size_kib).max().unwrap_or(0);
    let min = domains.iter().map(|(_, d)| d.size_kib).min().unwrap_or(0);
    // Asymétrie nette (≥ 1,5x) : un CCD porte le cache 3D.
    if min == 0 || max * 2 < min * 3 {
        return Ok(None);
    }
    let game: CpuSet = domains
        .iter()
        .filter(|(_, d)| d.size_kib == max)
        .flat_map(|(_, d)| d.cpus.iter().collect::<Vec<_>>())
        .collect();
    let bg = online.difference(&game);
    if game.is_empty() || bg.is_empty() {
        return Ok(None);
    }
    let mut parts: Vec<String> = domains
        .iter()
        .map(|(_, d)| format!("L3 {} Mio : {}", d.size_kib / 1024, d.cpus))
        .collect();
    parts.sort();
    let detail = format!(
        "Ryzen X3D : CCD à cache 3D {game} (jeu), autres {bg} (fond) [{}]",
        parts.join(" ; ")
    );
    Ok(Some(Topology {
        kind: TopologyKind::X3d,
        online: online.clone(),
        game,
        bg,
        detail,
    }))
}

fn detect_capacity(cpu_dir: &Path, online: &CpuSet) -> io::Result<Option<Topology>> {
    let mut caps = Vec::new();
    for cpu in online.iter() {
        let Some(c) = read_opt(&cpu_dir.join(format!("cpu{cpu}/cpu_capacity")))? else {
            return Ok(None);
        };
        let Ok(c) = c.parse::<u64>() else {
            return Ok(None);
        };
        caps.push((cpu, c));
    }
    let max = caps.iter().map(|(_, c)| *c).max().unwrap_or(0);
    let min = caps.iter().map(|(_, c)| *c).min().unwrap_or(0);
    // Écart > 10 % : cœurs asymétriques.
    if max == 0 || min * 10 >= max * 9 {
        return Ok(None);
    }
    let game: CpuSet = caps.iter().filter(|(_, c)| *c == max).map(|(cpu, _)| *cpu).collect();
    let bg = online.difference(&game);
    let detail = format!("cœurs asymétriques (cpu_capacity {min}..{max}) : jeu {game}, fond {bg}");
    Ok(Some(Topology {
        kind: TopologyKind::Hybrid,
        online: online.clone(),
        game,
        bg,
        detail,
    }))
}

/// Outils pour fabriquer un faux sysfs (tests unitaires et `topology --sysfs-root`).
pub mod fake {
    use super::*;

    pub struct FakeSysfs {
        pub root: PathBuf,
    }

    impl FakeSysfs {
        pub fn new(root: &Path, online: &str) -> io::Result<Self> {
            let cpu = root.join("sys/devices/system/cpu");
            fs::create_dir_all(&cpu)?;
            fs::write(cpu.join("online"), format!("{online}\n"))?;
            Ok(Self {
                root: root.to_path_buf(),
            })
        }

        /// Ajoute un L3 partagé par `cpus`, de taille `size` (« 98304K »).
        pub fn l3(&self, cpus: &str, size: &str) -> io::Result<&Self> {
            let set = CpuSet::parse(cpus).map_err(|e| io::Error::other(e.to_string()))?;
            for c in set.iter() {
                let d = self
                    .root
                    .join(format!("sys/devices/system/cpu/cpu{c}/cache/index3"));
                fs::create_dir_all(&d)?;
                fs::write(d.join("level"), "3\n")?;
                fs::write(d.join("size"), format!("{size}\n"))?;
                fs::write(d.join("shared_cpu_list"), format!("{cpus}\n"))?;
                // Un L1d pour vérifier qu'on ignore les autres niveaux.
                let l1 = self
                    .root
                    .join(format!("sys/devices/system/cpu/cpu{c}/cache/index0"));
                fs::create_dir_all(&l1)?;
                fs::write(l1.join("level"), "1\n")?;
                fs::write(l1.join("size"), "48K\n")?;
                fs::write(l1.join("shared_cpu_list"), format!("{c}\n"))?;
            }
            Ok(self)
        }

        pub fn hybrid(&self, p: &str, e: &str) -> io::Result<&Self> {
            for (name, cpus) in [("cpu_core", p), ("cpu_atom", e)] {
                let d = self.root.join(format!("sys/devices/{name}"));
                fs::create_dir_all(&d)?;
                fs::write(d.join("cpus"), format!("{cpus}\n"))?;
            }
            Ok(self)
        }

        pub fn capacity(&self, cpus: &str, cap: u32) -> io::Result<&Self> {
            let set = CpuSet::parse(cpus).map_err(|e| io::Error::other(e.to_string()))?;
            for c in set.iter() {
                let d = self.root.join(format!("sys/devices/system/cpu/cpu{c}"));
                fs::create_dir_all(&d)?;
                fs::write(d.join("cpu_capacity"), format!("{cap}\n"))?;
            }
            Ok(self)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::FakeSysfs;
    use super::*;

    fn tmp() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    #[test]
    fn x3d_dual_ccd_routes_game_to_vcache_ccd() {
        // 9950X3D : CCD0 (cache 3D, 96 Mio) = 0-7,16-23 ; CCD1 (32 Mio) = 8-15,24-31.
        let d = tmp();
        let f = FakeSysfs::new(d.path(), "0-31").unwrap();
        f.l3("0-7,16-23", "98304K").unwrap();
        f.l3("8-15,24-31", "32768K").unwrap();
        let t = Topology::detect(d.path()).unwrap();
        assert_eq!(t.kind, TopologyKind::X3d);
        assert_eq!(t.game.to_string(), "0-7,16-23");
        assert_eq!(t.bg.to_string(), "8-15,24-31");
        assert!(t.confine_by_default());
        assert!(t.detail.contains("96 Mio"));
    }

    #[test]
    fn x3d_vcache_on_second_ccd() {
        // Cas où le CCD à cache 3D n'est pas le CCD0.
        let d = tmp();
        let f = FakeSysfs::new(d.path(), "0-15").unwrap();
        f.l3("0-7", "32M").unwrap();
        f.l3("8-15", "96M").unwrap();
        let t = Topology::detect(d.path()).unwrap();
        assert_eq!(t.kind, TopologyKind::X3d);
        assert_eq!(t.game.to_string(), "8-15");
        assert_eq!(t.bg.to_string(), "0-7");
    }

    #[test]
    fn single_ccd_x3d_is_symmetric() {
        // 9800X3D : un seul CCD, un seul L3 -> rien à router.
        let d = tmp();
        let f = FakeSysfs::new(d.path(), "0-15").unwrap();
        f.l3("0-15", "98304K").unwrap();
        let t = Topology::detect(d.path()).unwrap();
        assert_eq!(t.kind, TopologyKind::Symmetric);
        assert!(t.game.is_empty());
        assert!(!t.confine_by_default());
    }

    #[test]
    fn dual_ccd_equal_l3_is_symmetric() {
        // 9950X (sans X3D) : deux CCD de 32 Mio.
        let d = tmp();
        let f = FakeSysfs::new(d.path(), "0-31").unwrap();
        f.l3("0-7,16-23", "32768K").unwrap();
        f.l3("8-15,24-31", "32768K").unwrap();
        assert_eq!(
            Topology::detect(d.path()).unwrap().kind,
            TopologyKind::Symmetric
        );
    }

    #[test]
    fn intel_hybrid_routes_game_to_p_cores() {
        // i7-13700K : 8 P-cores HT (0-15) + 8 E-cores (16-23), un seul L3.
        let d = tmp();
        let f = FakeSysfs::new(d.path(), "0-23").unwrap();
        f.l3("0-23", "30M").unwrap();
        f.hybrid("0-15", "16-23").unwrap();
        let t = Topology::detect(d.path()).unwrap();
        assert_eq!(t.kind, TopologyKind::Hybrid);
        assert_eq!(t.game.to_string(), "0-15");
        assert_eq!(t.bg.to_string(), "16-23");
        assert!(!t.confine_by_default());
    }

    #[test]
    fn hybrid_ignores_offline_cpus() {
        let d = tmp();
        let f = FakeSysfs::new(d.path(), "0-11,16-19").unwrap();
        f.hybrid("0-15", "16-23").unwrap();
        let t = Topology::detect(d.path()).unwrap();
        assert_eq!(t.game.to_string(), "0-11");
        assert_eq!(t.bg.to_string(), "16-19");
    }

    #[test]
    fn capacity_asymmetry_fallback() {
        let d = tmp();
        let f = FakeSysfs::new(d.path(), "0-7").unwrap();
        f.capacity("0-3", 1024).unwrap();
        f.capacity("4-7", 512).unwrap();
        let t = Topology::detect(d.path()).unwrap();
        assert_eq!(t.kind, TopologyKind::Hybrid);
        assert_eq!(t.game.to_string(), "0-3");
        assert_eq!(t.bg.to_string(), "4-7");
    }

    #[test]
    fn small_capacity_jitter_is_symmetric() {
        // Classement « preferred core » : écarts < 10 % -> symétrique.
        let d = tmp();
        let f = FakeSysfs::new(d.path(), "0-3").unwrap();
        f.capacity("0-1", 1024).unwrap();
        f.capacity("2-3", 990).unwrap();
        assert_eq!(
            Topology::detect(d.path()).unwrap().kind,
            TopologyKind::Symmetric
        );
    }

    #[test]
    fn manual_override_validation() {
        let online = CpuSet::parse("0-7").unwrap();
        let t = Topology::manual(
            TopologyKind::X3d,
            online.clone(),
            CpuSet::parse("0-3").unwrap(),
            None,
        )
        .unwrap();
        assert_eq!(t.bg.to_string(), "4-7");
        assert!(Topology::manual(
            TopologyKind::X3d,
            online.clone(),
            CpuSet::parse("6-9").unwrap(),
            None
        )
        .is_err());
        assert!(
            Topology::manual(TopologyKind::Hybrid, online, CpuSet::new(), None).is_err()
        );
    }

    #[test]
    fn cache_size_units() {
        assert_eq!(parse_cache_size("98304K"), Some(98304));
        assert_eq!(parse_cache_size("32M"), Some(32768));
        assert_eq!(parse_cache_size("1G"), Some(1048576));
        assert_eq!(parse_cache_size("bad"), None);
    }

    #[test]
    fn missing_online_file_is_an_error() {
        let d = tmp();
        assert!(Topology::detect(d.path()).is_err());
    }
}
