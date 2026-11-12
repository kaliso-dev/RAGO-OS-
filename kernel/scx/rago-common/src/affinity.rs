// SPDX-License-Identifier: GPL-2.0
//
// Affinité CPU stricte (sched_setaffinity). Utilisée pour confiner le jeu sur
// le CCD à cache 3D d'un Ryzen X3D : l'affinité est héritée par tous les
// threads et processus enfants, et elle reste respectée même si scx_rago est
// éjecté (filet EEVDF+BORE), car c'est le noyau qui l'applique.

use std::io;
use std::path::Path;

use crate::cpuset::CpuSet;
use crate::procfs;

/// Taille de cpu_set_t de la glibc : 1024 CPU.
const SETSIZE: u32 = (std::mem::size_of::<libc::cpu_set_t>() * 8) as u32;

/// Applique `set` au thread `tid` (0 = thread appelant).
pub fn set_thread(tid: u32, set: &CpuSet) -> io::Result<()> {
    if set.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "masque CPU vide"));
    }
    // SAFETY: cpu_set_t est un simple tableau de bits ; zeroed est valide.
    let mut cs: libc::cpu_set_t = unsafe { std::mem::zeroed() };
    for cpu in set.iter() {
        if cpu >= SETSIZE {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("CPU {cpu} au-delà de {SETSIZE}"),
            ));
        }
        // SAFETY: cpu < CPU_SETSIZE vérifié ci-dessus.
        unsafe { libc::CPU_SET(cpu as usize, &mut cs) };
    }
    // SAFETY: pointeur et taille d'un cpu_set_t valide.
    let rc = unsafe {
        libc::sched_setaffinity(tid as libc::pid_t, std::mem::size_of::<libc::cpu_set_t>(), &cs)
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Lit l'affinité du thread `tid` (0 = thread appelant).
pub fn get_thread(tid: u32) -> io::Result<CpuSet> {
    // SAFETY: cpu_set_t zeroed valide, rempli par le noyau.
    let mut cs: libc::cpu_set_t = unsafe { std::mem::zeroed() };
    let rc = unsafe {
        libc::sched_getaffinity(tid as libc::pid_t, std::mem::size_of::<libc::cpu_set_t>(), &mut cs)
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((0..SETSIZE)
        .filter(|&c| unsafe { libc::CPU_ISSET(c as usize, &cs) })
        .collect())
}

/// Applique `set` à tous les threads de `pid` et de ses descendants.
/// Renvoie le nombre de threads modifiés. Les threads disparus entre-temps
/// sont ignorés.
pub fn set_tree(proc_root: &Path, pid: u32, set: &CpuSet) -> io::Result<usize> {
    let mut pids = vec![pid];
    pids.extend(procfs::descendants(proc_root, pid)?);
    let mut n = 0;
    for p in pids {
        let Ok(tids) = procfs::threads(proc_root, p) else {
            continue;
        };
        for t in tids {
            match set_thread(t, set) {
                Ok(()) => n += 1,
                Err(e) if e.raw_os_error() == Some(libc::ESRCH) => {}
                Err(e) => return Err(e),
            }
        }
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_and_restore_own_affinity() {
        let orig = get_thread(0).unwrap();
        assert!(!orig.is_empty());
        let first: CpuSet = orig.iter().take(1).collect();
        set_thread(0, &first).unwrap();
        assert_eq!(get_thread(0).unwrap(), first);
        set_thread(0, &orig).unwrap();
        assert_eq!(get_thread(0).unwrap(), orig);
    }

    #[test]
    fn empty_set_is_rejected() {
        assert!(set_thread(0, &CpuSet::new()).is_err());
    }
}
