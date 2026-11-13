// SPDX-License-Identifier: GPL-2.0
//
// Hooks : points de branchement vers les modules qui ne sont pas encore codés.
//
//   gpu-clocks        (M9 GPU)          horloges GPU du profil, côté Linux
//   windows-security  (M5 / M6 switch)  profil de sécurité du micro-Windows,
//                                        écrit dans RAGO-COMM avant le switch
//
// Un hook est un exécutable posé dans le dossier des hooks
// (/usr/lib/rago/hooks par défaut) par le module qui le fournit. Tant qu'il
// n'existe pas, rago-profiled le signale « en attente » et continue : rien
// n'est appliqué, rien ne casse. Contrat complet : profiles/README.md.
//
// Les hooks tournent en root (comme le démon) : le fichier et son dossier
// doivent appartenir à root (ou à l'utilisateur du démon, pour les tests) et
// ne pas être modifiables par le groupe ou les autres. L'environnement est
// vidé, la durée limitée.

use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

pub const DEFAULT_HOOKS_DIR: &str = "/usr/lib/rago/hooks";
pub const HOOK_GPU_CLOCKS: &str = "gpu-clocks";
pub const HOOK_WINDOWS_SECURITY: &str = "windows-security";

/// Sortie gardée d'un hook (octets).
const MAX_OUTPUT: usize = 4096;
const HOOK_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookOutcome {
    /// Le module qui fournit ce hook n'est pas installé.
    Absent,
    /// Hook présent mais refusé (droits dangereux).
    Refused(String),
    /// Code 0. Contient la dernière ligne de la sortie standard.
    Ok(String),
    /// Code non nul, délai dépassé ou lancement impossible.
    Failed(String),
}

#[derive(Debug, Clone)]
pub struct Hooks {
    dir: PathBuf,
    timeout: Duration,
}

fn euid() -> u32 {
    // SAFETY: geteuid n'échoue jamais.
    unsafe { libc::geteuid() }
}

/// Fichier ou dossier sûr pour un exécutable lancé en root.
fn check_owner(path: &Path, what: &str) -> Result<(), String> {
    let m = fs::metadata(path).map_err(|e| format!("{what} {} : {e}", path.display()))?;
    let me = euid();
    if m.uid() != 0 && m.uid() != me {
        return Err(format!(
            "{what} {} appartient à l'uid {} (root attendu)",
            path.display(),
            m.uid()
        ));
    }
    if m.mode() & 0o022 != 0 {
        return Err(format!(
            "{what} {} modifiable par le groupe ou les autres (mode {:o})",
            path.display(),
            m.mode() & 0o7777
        ));
    }
    Ok(())
}

fn keep_tail(buf: &[u8]) -> String {
    let s = String::from_utf8_lossy(buf);
    let s = s.trim();
    let start = s.len().saturating_sub(MAX_OUTPUT);
    let mut i = start;
    while !s.is_char_boundary(i) {
        i += 1;
    }
    s[i..].to_string()
}

/// Lit un tuyau dans un thread ; le résultat arrive par le canal.
fn spawn_reader<R: Read + Send + 'static>(mut r: R) -> mpsc::Receiver<Vec<u8>> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut out = Vec::new();
        let mut chunk = [0u8; 1024];
        loop {
            match r.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    out.extend_from_slice(&chunk[..n]);
                    if out.len() > 4 * MAX_OUTPUT {
                        let cut = out.len() - 2 * MAX_OUTPUT;
                        out.drain(..cut);
                    }
                }
            }
        }
        let _ = tx.send(out);
    });
    rx
}

/// Tue tout le groupe de processus du hook (ses enfants en arrière-plan aussi).
fn kill_group(pgid: u32) {
    // SAFETY: simple appel système ; pgid est le groupe créé pour le hook.
    unsafe {
        libc::kill(-(pgid as libc::pid_t), libc::SIGKILL);
    }
}

impl Hooks {
    pub fn new(dir: PathBuf, timeout: Duration) -> Self {
        Self { dir, timeout }
    }

    pub fn path(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }

    pub fn is_present(&self, name: &str) -> bool {
        self.path(name).exists()
    }

    /// Lance un hook : `<dossier>/<name> <args…>`, profil effectif en JSON
    /// sur l'entrée standard, variables `env` seulement (plus PATH et LANG).
    pub fn run(&self, name: &str, args: &[&str], env: &[(&str, String)], stdin: &str) -> HookOutcome {
        let path = self.path(name);
        match fs::symlink_metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return HookOutcome::Absent,
            Err(e) => return HookOutcome::Refused(format!("{} : {e}", path.display())),
            Ok(_) => {}
        }
        if let Err(e) = check_owner(&self.dir, "dossier des hooks") {
            return HookOutcome::Refused(e);
        }
        if let Err(e) = check_owner(&path, "hook") {
            return HookOutcome::Refused(e);
        }
        match fs::metadata(&path) {
            Ok(m) if m.is_file() && m.permissions().mode() & 0o111 != 0 => {}
            Ok(_) => {
                return HookOutcome::Refused(format!(
                    "{} n'est pas un fichier exécutable",
                    path.display()
                ));
            }
            Err(e) => return HookOutcome::Refused(format!("{} : {e}", path.display())),
        }

        let mut cmd = Command::new(&path);
        cmd.args(args)
            .env_clear()
            .env("PATH", HOOK_PATH)
            .env("LANG", "C.UTF-8")
            .current_dir("/")
            // Groupe à lui : en cas de délai dépassé, on tue aussi ses enfants.
            .process_group(0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (k, v) in env {
            cmd.env(k, v);
        }
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => return HookOutcome::Failed(format!("lancement de {} impossible : {e}", path.display())),
        };
        if let Some(mut si) = child.stdin.take() {
            // Un hook qui ne lit pas son entrée ne doit pas bloquer le démon.
            let data = stdin.as_bytes().to_vec();
            thread::spawn(move || {
                let _ = si.write_all(&data);
            });
        }
        let out = spawn_reader(child.stdout.take().expect("stdout"));
        let err = spawn_reader(child.stderr.take().expect("stderr"));
        let pgid = child.id();
        let deadline = Instant::now() + self.timeout;
        let status = loop {
            match child.try_wait() {
                Ok(Some(s)) => break Some(s),
                Ok(None) if Instant::now() >= deadline => {
                    kill_group(pgid);
                    let _ = child.wait();
                    break None;
                }
                Ok(None) => thread::sleep(Duration::from_millis(20)),
                Err(e) => {
                    kill_group(pgid);
                    return HookOutcome::Failed(format!("attente du hook : {e}"));
                }
            }
        };
        // Un enfant resté en arrière-plan peut garder les tuyaux ouverts : on
        // ne l'attend pas plus d'une seconde.
        let collect = |rx: &mpsc::Receiver<Vec<u8>>| -> String {
            match rx.recv_timeout(Duration::from_secs(1)) {
                Ok(b) => keep_tail(&b),
                Err(_) => {
                    kill_group(pgid);
                    rx.recv_timeout(Duration::from_secs(1))
                        .map(|b| keep_tail(&b))
                        .unwrap_or_default()
                }
            }
        };
        let out = collect(&out);
        let err = collect(&err);
        match status {
            None => HookOutcome::Failed(format!(
                "{name} : délai de {} s dépassé, arrêté",
                self.timeout.as_secs()
            )),
            Some(s) if s.success() => {
                HookOutcome::Ok(out.lines().last().unwrap_or("").trim().to_string())
            }
            Some(s) => {
                let why = match s.code() {
                    Some(c) => format!("code {c}"),
                    None => "tué par un signal".into(),
                };
                let detail = err.lines().last().or(out.lines().last()).unwrap_or("");
                HookOutcome::Failed(format!("{name} : {why} {detail}").trim().to_string())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hook(dir: &Path, name: &str, body: &str, mode: u32) {
        let p = dir.join(name);
        fs::write(&p, body).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(mode)).unwrap();
    }

    fn hooks(dir: &Path) -> Hooks {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o755)).unwrap();
        Hooks::new(dir.to_path_buf(), Duration::from_secs(5))
    }

    #[test]
    fn absent_hook_is_pending_not_an_error() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(hooks(d.path()).run("gpu-clocks", &["apply"], &[], "{}"), HookOutcome::Absent);
    }

    #[test]
    fn hook_gets_args_env_and_stdin_but_not_the_daemon_env() {
        let d = tempfile::tempdir().unwrap();
        let log = d.path().join("log");
        hook(
            d.path(),
            "gpu-clocks",
            &format!(
                "#!/bin/sh\nprintf '%s|%s|%s|%s\\n' \"$1\" \"$RAGO_GPU_CLOCKS_MODE\" \"${{HOME:-vide}}\" \"$(cat)\" > {}\necho appliqué\n",
                log.display()
            ),
            0o755,
        );
        let r = hooks(d.path()).run(
            "gpu-clocks",
            &["apply"],
            &[("RAGO_GPU_CLOCKS_MODE", "max".into())],
            "{\"id\":\"x\"}",
        );
        assert_eq!(r, HookOutcome::Ok("appliqué".into()));
        assert_eq!(fs::read_to_string(&log).unwrap(), "apply|max|vide|{\"id\":\"x\"}\n");
    }

    #[test]
    fn failing_slow_and_unsafe_hooks() {
        let d = tempfile::tempdir().unwrap();
        hook(d.path(), "echec", "#!/bin/sh\necho 'carte absente' >&2\nexit 4\n", 0o755);
        hook(d.path(), "lent", "#!/bin/sh\nsleep 30\n", 0o755);
        hook(d.path(), "fond", "#!/bin/sh\nsleep 30 &\necho lancé\n", 0o755);
        hook(d.path(), "ouvert", "#!/bin/sh\nexit 0\n", 0o777);
        hook(d.path(), "non-exec", "#!/bin/sh\nexit 0\n", 0o644);
        let mut h = hooks(d.path());
        match h.run("echec", &[], &[], "") {
            HookOutcome::Failed(m) => assert!(m.contains("code 4") && m.contains("carte absente"), "{m}"),
            o => panic!("{o:?}"),
        }
        assert!(matches!(h.run("ouvert", &[], &[], ""), HookOutcome::Refused(_)));
        assert!(matches!(h.run("non-exec", &[], &[], ""), HookOutcome::Refused(_)));
        h.timeout = Duration::from_millis(300);
        let t = Instant::now();
        assert!(matches!(h.run("lent", &[], &[], ""), HookOutcome::Failed(m) if m.contains("délai")));
        assert!(t.elapsed() < Duration::from_secs(5));
        // Un enfant en arrière-plan qui garde la sortie ne bloque pas le démon.
        h.timeout = Duration::from_secs(5);
        let t = Instant::now();
        assert_eq!(h.run("fond", &[], &[], ""), HookOutcome::Ok("lancé".into()));
        assert!(t.elapsed() < Duration::from_secs(5));
        // Dossier modifiable par tous : tout est refusé.
        fs::set_permissions(d.path(), fs::Permissions::from_mode(0o777)).unwrap();
        assert!(matches!(h.run("echec", &[], &[], ""), HookOutcome::Refused(m) if m.contains("dossier")));
    }
}
