// SPDX-License-Identifier: GPL-2.0
//
// Ensemble de CPU, lu et écrit au format des listes du noyau (« 0-3,8,10-11 »).

use std::collections::BTreeSet;
use std::fmt;
use std::str::FromStr;

/// Nombre max de CPU gérés (= LAVD_CPU_ID_MAX côté BPF).
pub const MAX_CPUS: u32 = 8192;

#[derive(Clone, Default, PartialEq, Eq, Hash)]
pub struct CpuSet(BTreeSet<u32>);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError(pub String);

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "liste de CPU invalide : {}", self.0)
    }
}

impl std::error::Error for ParseError {}

impl CpuSet {
    pub fn new() -> Self {
        Self(BTreeSet::new())
    }

    pub fn insert(&mut self, cpu: u32) {
        self.0.insert(cpu);
    }

    pub fn contains(&self, cpu: u32) -> bool {
        self.0.contains(&cpu)
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = u32> + '_ {
        self.0.iter().copied()
    }

    pub fn union(&self, other: &CpuSet) -> CpuSet {
        CpuSet(self.0.union(&other.0).copied().collect())
    }

    pub fn intersection(&self, other: &CpuSet) -> CpuSet {
        CpuSet(self.0.intersection(&other.0).copied().collect())
    }

    pub fn difference(&self, other: &CpuSet) -> CpuSet {
        CpuSet(self.0.difference(&other.0).copied().collect())
    }

    pub fn is_subset(&self, other: &CpuSet) -> bool {
        self.0.is_subset(&other.0)
    }

    /// Masque en mots de 64 bits (bit n = CPU n), `words` mots.
    pub fn to_words(&self, words: usize) -> Vec<u64> {
        let mut out = vec![0u64; words];
        for cpu in self.iter() {
            let w = (cpu / 64) as usize;
            if w < words {
                out[w] |= 1u64 << (cpu % 64);
            }
        }
        out
    }

    /// Analyse une liste au format noyau. Une chaîne vide donne un ensemble vide.
    pub fn parse(s: &str) -> Result<Self, ParseError> {
        let mut set = BTreeSet::new();
        let s = s.trim();
        if s.is_empty() {
            return Ok(Self(set));
        }
        for part in s.split(',') {
            let part = part.trim();
            if part.is_empty() {
                return Err(ParseError(format!("élément vide dans « {s} »")));
            }
            let (lo, hi) = match part.split_once('-') {
                Some((a, b)) => (parse_cpu(a, s)?, parse_cpu(b, s)?),
                None => {
                    let c = parse_cpu(part, s)?;
                    (c, c)
                }
            };
            if lo > hi {
                return Err(ParseError(format!("intervalle inversé « {part} »")));
            }
            for c in lo..=hi {
                set.insert(c);
            }
        }
        Ok(Self(set))
    }
}

fn parse_cpu(t: &str, whole: &str) -> Result<u32, ParseError> {
    let v: u32 = t
        .trim()
        .parse()
        .map_err(|_| ParseError(format!("« {t} » n'est pas un numéro de CPU dans « {whole} »")))?;
    if v >= MAX_CPUS {
        return Err(ParseError(format!("CPU {v} au-delà du maximum {MAX_CPUS}")));
    }
    Ok(v)
}

impl FromStr for CpuSet {
    type Err = ParseError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

impl FromIterator<u32> for CpuSet {
    fn from_iter<I: IntoIterator<Item = u32>>(iter: I) -> Self {
        Self(iter.into_iter().collect())
    }
}

impl fmt::Display for CpuSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut first = true;
        let mut it = self.0.iter().copied().peekable();
        while let Some(start) = it.next() {
            let mut end = start;
            while let Some(&n) = it.peek() {
                if n == end + 1 {
                    end = n;
                    it.next();
                } else {
                    break;
                }
            }
            if !first {
                f.write_str(",")?;
            }
            first = false;
            if start == end {
                write!(f, "{start}")?;
            } else {
                write!(f, "{start}-{end}")?;
            }
        }
        Ok(())
    }
}

impl fmt::Debug for CpuSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "CpuSet({self})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_format_roundtrip() {
        let s = CpuSet::parse("0-3,8,10-11").unwrap();
        assert_eq!(s.len(), 7);
        assert!(s.contains(2) && s.contains(8) && s.contains(11));
        assert!(!s.contains(9));
        assert_eq!(s.to_string(), "0-3,8,10-11");
    }

    #[test]
    fn parse_empty_and_whitespace() {
        assert!(CpuSet::parse("").unwrap().is_empty());
        assert!(CpuSet::parse("  \n").unwrap().is_empty());
        assert_eq!(CpuSet::parse(" 5 \n").unwrap().to_string(), "5");
    }

    #[test]
    fn parse_rejects_garbage() {
        assert!(CpuSet::parse("a-b").is_err());
        assert!(CpuSet::parse("3-1").is_err());
        assert!(CpuSet::parse("1,,2").is_err());
        assert!(CpuSet::parse("99999").is_err());
    }

    #[test]
    fn set_operations() {
        let a = CpuSet::parse("0-7").unwrap();
        let b = CpuSet::parse("4-11").unwrap();
        assert_eq!(a.intersection(&b).to_string(), "4-7");
        assert_eq!(a.difference(&b).to_string(), "0-3");
        assert_eq!(a.union(&b).to_string(), "0-11");
        assert!(CpuSet::parse("1-2").unwrap().is_subset(&a));
    }

    #[test]
    fn words_layout() {
        let s = CpuSet::parse("0,63,64,130").unwrap();
        let w = s.to_words(3);
        assert_eq!(w[0], 1 | (1u64 << 63));
        assert_eq!(w[1], 1);
        assert_eq!(w[2], 1 << 2);
    }
}
