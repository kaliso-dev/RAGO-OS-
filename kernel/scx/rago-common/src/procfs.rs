// SPDX-License-Identifier: GPL-2.0
//
// Lectures /proc nécessaires au canal launcher -> ordonnanceur. Toutes les
// fonctions prennent la racine de procfs (« /proc » en production) pour être
// testables.

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::fs;
use std::io;
use std::path::Path;

fn status_field(proc_root: &Path, pid: u32, key: &str) -> io::Result<String> {
    let s = fs::read_to_string(proc_root.join(format!("{pid}/status")))?;
    for line in s.lines() {
        if let Some(rest) = line.strip_prefix(key).and_then(|r| r.strip_prefix(':')) {
            return Ok(rest.trim().to_string());
        }
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        format!("champ {key} absent de /proc/{pid}/status"),
    ))
}

/// UID réel du processus ou du thread `pid`.
pub fn real_uid(proc_root: &Path, pid: u32) -> io::Result<u32> {
    let v = status_field(proc_root, pid, "Uid")?;
    v.split_ascii_whitespace()
        .next()
        .and_then(|u| u.parse().ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, format!("Uid illisible : {v}")))
}

/// TGID (PID du processus) auquel appartient le thread `tid`.
pub fn tgid_of(proc_root: &Path, tid: u32) -> io::Result<u32> {
    let v = status_field(proc_root, tid, "Tgid")?;
    v.parse()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, format!("Tgid illisible : {v}")))
}

/// Vrai si /proc/<pid> existe (processus ou thread vivant).
pub fn exists(proc_root: &Path, pid: u32) -> bool {
    proc_root.join(pid.to_string()).exists()
}

/// Nom (comm) du thread `tid`.
pub fn comm(proc_root: &Path, tid: u32) -> io::Result<String> {
    Ok(fs::read_to_string(proc_root.join(format!("{tid}/comm")))?
        .trim_end()
        .to_string())
}

/// Threads (TID) du processus `pid`.
pub fn threads(proc_root: &Path, pid: u32) -> io::Result<Vec<u32>> {
    let mut v: Vec<u32> = fs::read_dir(proc_root.join(format!("{pid}/task")))?
        .filter_map(|e| e.ok()?.file_name().to_str()?.parse().ok())
        .collect();
    v.sort_unstable();
    Ok(v)
}

/// PPID d'après /proc/<pid>/stat (le comm peut contenir des espaces et
/// des parenthèses : on part de la dernière « ) »).
pub fn ppid(proc_root: &Path, pid: u32) -> io::Result<u32> {
    let s = fs::read_to_string(proc_root.join(format!("{pid}/stat")))?;
    parse_stat_ppid(&s).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, format!("/proc/{pid}/stat illisible"))
    })
}

pub fn parse_stat_ppid(stat: &str) -> Option<u32> {
    let after = &stat[stat.rfind(')')? + 1..];
    let mut it = after.split_ascii_whitespace();
    let _state = it.next()?;
    it.next()?.parse().ok()
}

/// Numéro du CPU sur lequel le thread a tourné en dernier (champ 39 de stat).
pub fn last_cpu(proc_root: &Path, pid: u32, tid: u32) -> io::Result<u32> {
    let s = fs::read_to_string(proc_root.join(format!("{pid}/task/{tid}/stat")))?;
    parse_stat_cpu(&s).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, format!("stat de {tid} illisible"))
    })
}

pub fn parse_stat_cpu(stat: &str) -> Option<u32> {
    let after = &stat[stat.rfind(')')? + 1..];
    // Après « ) » : champ 3 (state) ... le champ 39 (processor) est le 37e ici.
    after.split_ascii_whitespace().nth(36)?.parse().ok()
}

/// Tous les descendants (processus) de `pid`, `pid` exclu.
pub fn descendants(proc_root: &Path, pid: u32) -> io::Result<Vec<u32>> {
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for e in fs::read_dir(proc_root)? {
        let Ok(e) = e else { continue };
        let Some(p) = e.file_name().to_str().and_then(|n| n.parse::<u32>().ok()) else {
            continue;
        };
        if let Ok(pp) = ppid(proc_root, p) {
            children.entry(pp).or_default().push(p);
        }
    }
    let mut out = BTreeSet::new();
    let mut q = VecDeque::from([pid]);
    while let Some(cur) = q.pop_front() {
        if let Some(kids) = children.get(&cur) {
            for &k in kids {
                if k != pid && out.insert(k) {
                    q.push_back(k);
                }
            }
        }
    }
    Ok(out.into_iter().collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_proc(dir: &Path, pid: u32, ppid: u32, uid: u32, tids: &[u32]) {
        let p = dir.join(pid.to_string());
        fs::create_dir_all(p.join("task")).unwrap();
        fs::write(
            p.join("status"),
            format!("Name:\tgame\nTgid:\t{pid}\nPPid:\t{ppid}\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n"),
        )
        .unwrap();
        fs::write(
            p.join("stat"),
            format!("{pid} (my game (x64)) S {ppid} 1 1 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 5 0 0\n"),
        )
        .unwrap();
        fs::write(p.join("comm"), "game\n").unwrap();
        for t in tids {
            fs::create_dir_all(p.join(format!("task/{t}"))).unwrap();
        }
    }

    #[test]
    fn status_and_tree() {
        let d = tempfile::tempdir().unwrap();
        fake_proc(d.path(), 100, 1, 1000, &[100, 101, 102]);
        fake_proc(d.path(), 200, 100, 1000, &[200]);
        fake_proc(d.path(), 300, 200, 1000, &[300]);
        fake_proc(d.path(), 400, 1, 0, &[400]);
        assert_eq!(real_uid(d.path(), 100).unwrap(), 1000);
        assert_eq!(real_uid(d.path(), 400).unwrap(), 0);
        assert_eq!(tgid_of(d.path(), 100).unwrap(), 100);
        assert_eq!(threads(d.path(), 100).unwrap(), vec![100, 101, 102]);
        assert_eq!(ppid(d.path(), 200).unwrap(), 100);
        assert_eq!(descendants(d.path(), 100).unwrap(), vec![200, 300]);
        assert!(descendants(d.path(), 400).unwrap().is_empty());
        assert!(exists(d.path(), 300));
        assert!(!exists(d.path(), 999));
        assert_eq!(comm(d.path(), 100).unwrap(), "game");
    }

    #[test]
    fn stat_parsing_with_tricky_comm() {
        let line = "123 (a) b) c) R 77 123 123 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 11 0 0";
        assert_eq!(parse_stat_ppid(line), Some(77));
        assert_eq!(parse_stat_cpu(line), Some(11));
    }

    #[test]
    fn real_proc_self() {
        let me = std::process::id();
        let root = Path::new("/proc");
        assert_eq!(tgid_of(root, me).unwrap(), me);
        assert!(threads(root, me).unwrap().contains(&me));
        assert_eq!(real_uid(root, me).unwrap(), unsafe { libc::getuid() });
        assert!(last_cpu(root, me, me).is_ok());
    }
}
