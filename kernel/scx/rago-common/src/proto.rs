// SPDX-License-Identifier: GPL-2.0
//
// Protocole du canal launcher -> scx_rago.
//
// Transport : socket Unix flux /run/rago/sched-hint.sock (root:rago, 0660).
// Une requête = une ligne ASCII terminée par '\n' (512 octets max). Le serveur
// répond par zéro ou plusieurs lignes de données puis une ligne finale
// « OK ... » ou « ERR <CODE> <message> ».
//
//   HELLO <version>      -> OK proto=1 abi=1 topo=x3d game=0-7,16-23 bg=8-15,24-31 confine=1
//   TAG <pid>            -> OK            (tague le processus <pid> et ses futurs enfants : GAME)
//   TAGTID <tid>         -> OK            (tague le thread <tid> : RENDER)
//   UNTAG <pid>          -> OK removed=N  (retire <pid> et tout l'arbre tagué depuis lui)
//   COMM <motif>         -> OK            (ajoute un préfixe de nom de thread de rendu)
//   LIST                 -> HINT tgid <id> <classe> <flags> <racine> <uid> ... puis OK count=N
//   STATUS               -> OK clé=valeur ...
//
// Le serveur identifie l'appelant par SO_PEERCRED : un utilisateur ne peut
// taguer que ses propres processus (root : tous).

use std::fmt;

pub const MAX_LINE: usize = 512;

pub const F_LAUNCHER: u32 = 1 << 0;
pub const F_INHERITED: u32 = 1 << 1;
pub const F_THREAD: u32 = 1 << 2;

/// Taille de struct rago_hint (rago_intf.h).
pub const HINT_SIZE: usize = 24;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum HintClass {
    None = 0,
    Game = 1,
    Render = 2,
}

impl HintClass {
    pub fn from_u32(v: u32) -> Option<Self> {
        match v {
            0 => Some(HintClass::None),
            1 => Some(HintClass::Game),
            2 => Some(HintClass::Render),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            HintClass::None => "none",
            HintClass::Game => "game",
            HintClass::Render => "render",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "none" => Some(HintClass::None),
            "game" => Some(HintClass::Game),
            "render" => Some(HintClass::Render),
            _ => None,
        }
    }
}

impl fmt::Display for HintClass {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Miroir de struct rago_hint (24 octets, little-endian x86-64).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hint {
    pub class: HintClass,
    pub flags: u32,
    pub root_tgid: u32,
    pub owner_uid: u32,
    pub tagged_ns: u64,
}

impl Hint {
    pub fn encode(&self) -> [u8; HINT_SIZE] {
        let mut b = [0u8; HINT_SIZE];
        b[0..4].copy_from_slice(&(self.class as u32).to_ne_bytes());
        b[4..8].copy_from_slice(&self.flags.to_ne_bytes());
        b[8..12].copy_from_slice(&self.root_tgid.to_ne_bytes());
        b[12..16].copy_from_slice(&self.owner_uid.to_ne_bytes());
        b[16..24].copy_from_slice(&self.tagged_ns.to_ne_bytes());
        b
    }

    pub fn decode(b: &[u8]) -> Option<Self> {
        if b.len() != HINT_SIZE {
            return None;
        }
        let u32_at = |i: usize| u32::from_ne_bytes(b[i..i + 4].try_into().unwrap());
        Some(Self {
            class: HintClass::from_u32(u32_at(0))?,
            flags: u32_at(4),
            root_tgid: u32_at(8),
            owner_uid: u32_at(12),
            tagged_ns: u64::from_ne_bytes(b[16..24].try_into().unwrap()),
        })
    }
}

/// Horloge CLOCK_MONOTONIC en ns (même base que bpf_ktime_get_ns()).
pub fn monotonic_ns() -> u64 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: ts est un timespec valide et CLOCK_MONOTONIC existe toujours.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    (ts.tv_sec as u64) * 1_000_000_000 + ts.tv_nsec as u64
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Request {
    Hello { version: u32 },
    Tag { pid: u32 },
    TagThread { tid: u32 },
    Untag { pid: u32 },
    Comm { pattern: String },
    List,
    Status,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrCode {
    Inval,
    Perm,
    Srch,
    Limit,
    Io,
    Version,
}

impl ErrCode {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrCode::Inval => "EINVAL",
            ErrCode::Perm => "EPERM",
            ErrCode::Srch => "ESRCH",
            ErrCode::Limit => "ELIMIT",
            ErrCode::Io => "EIO",
            ErrCode::Version => "EVERSION",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "EINVAL" => ErrCode::Inval,
            "EPERM" => ErrCode::Perm,
            "ESRCH" => ErrCode::Srch,
            "ELIMIT" => ErrCode::Limit,
            "EIO" => ErrCode::Io,
            "EVERSION" => ErrCode::Version,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProtoError {
    pub code: ErrCode,
    pub msg: String,
}

impl ProtoError {
    pub fn new(code: ErrCode, msg: impl Into<String>) -> Self {
        Self {
            code,
            msg: msg.into(),
        }
    }

    /// Ligne « ERR <CODE> <message> » (le message est mis sur une ligne).
    pub fn to_line(&self) -> String {
        let msg: String = self
            .msg
            .chars()
            .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
            .collect();
        format!("ERR {} {}", self.code.as_str(), msg)
    }
}

impl fmt::Display for ProtoError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} : {}", self.code.as_str(), self.msg)
    }
}

impl std::error::Error for ProtoError {}

fn parse_id(s: Option<&str>, what: &str) -> Result<u32, ProtoError> {
    let s = s.ok_or_else(|| ProtoError::new(ErrCode::Inval, format!("{what} manquant")))?;
    let v: u32 = s
        .parse()
        .map_err(|_| ProtoError::new(ErrCode::Inval, format!("{what} invalide : {s}")))?;
    if v == 0 {
        return Err(ProtoError::new(ErrCode::Inval, format!("{what} 0 interdit")));
    }
    Ok(v)
}

/// Un motif de nom de thread valide : 1 à 15 caractères ASCII imprimables, sans espace.
pub fn valid_comm_pattern(p: &str) -> bool {
    !p.is_empty()
        && p.len() <= crate::COMM_MAX
        && p.bytes().all(|b| b.is_ascii_graphic())
}

impl Request {
    pub fn parse(line: &str) -> Result<Self, ProtoError> {
        if line.len() > MAX_LINE {
            return Err(ProtoError::new(ErrCode::Inval, "ligne trop longue"));
        }
        let mut it = line.split_ascii_whitespace();
        let verb = it
            .next()
            .ok_or_else(|| ProtoError::new(ErrCode::Inval, "requête vide"))?;
        let req = match verb {
            "HELLO" => Request::Hello {
                version: parse_id(it.next(), "version")?,
            },
            "TAG" => Request::Tag {
                pid: parse_id(it.next(), "pid")?,
            },
            "TAGTID" => Request::TagThread {
                tid: parse_id(it.next(), "tid")?,
            },
            "UNTAG" => Request::Untag {
                pid: parse_id(it.next(), "pid")?,
            },
            "COMM" => {
                let p = it
                    .next()
                    .ok_or_else(|| ProtoError::new(ErrCode::Inval, "motif manquant"))?;
                if !valid_comm_pattern(p) {
                    return Err(ProtoError::new(
                        ErrCode::Inval,
                        format!("motif invalide (1 à {} caractères ASCII) : {p}", crate::COMM_MAX),
                    ));
                }
                Request::Comm {
                    pattern: p.to_string(),
                }
            }
            "LIST" => Request::List,
            "STATUS" => Request::Status,
            other => {
                return Err(ProtoError::new(
                    ErrCode::Inval,
                    format!("verbe inconnu : {other}"),
                ));
            }
        };
        if it.next().is_some() {
            return Err(ProtoError::new(ErrCode::Inval, "argument en trop"));
        }
        Ok(req)
    }

    pub fn to_line(&self) -> String {
        match self {
            Request::Hello { version } => format!("HELLO {version}"),
            Request::Tag { pid } => format!("TAG {pid}"),
            Request::TagThread { tid } => format!("TAGTID {tid}"),
            Request::Untag { pid } => format!("UNTAG {pid}"),
            Request::Comm { pattern } => format!("COMM {pattern}"),
            Request::List => "LIST".into(),
            Request::Status => "STATUS".into(),
        }
    }
}

/// Analyse « clé=valeur clé=valeur » d'une ligne OK.
pub fn parse_kv(s: &str) -> Vec<(String, String)> {
    s.split_ascii_whitespace()
        .filter_map(|kv| kv.split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

/// Entrée renvoyée par LIST.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ListEntry {
    /// "tgid" (processus) ou "tid" (thread).
    pub kind: String,
    pub id: u32,
    pub class: HintClass,
    pub flags: u32,
    pub root: u32,
    pub uid: u32,
}

impl ListEntry {
    pub fn to_line(&self) -> String {
        format!(
            "HINT {} {} {} {} {} {}",
            self.kind, self.id, self.class, self.flags, self.root, self.uid
        )
    }

    pub fn parse(line: &str) -> Option<Self> {
        let mut it = line.split_ascii_whitespace();
        if it.next()? != "HINT" {
            return None;
        }
        let kind = it.next()?.to_string();
        if kind != "tgid" && kind != "tid" {
            return None;
        }
        Some(Self {
            kind,
            id: it.next()?.parse().ok()?,
            class: HintClass::parse(it.next()?)?,
            flags: it.next()?.parse().ok()?,
            root: it.next()?.parse().ok()?,
            uid: it.next()?.parse().ok()?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hint_roundtrip_and_layout() {
        let h = Hint {
            class: HintClass::Render,
            flags: F_LAUNCHER | F_THREAD,
            root_tgid: 4242,
            owner_uid: 1000,
            tagged_ns: 0x0102_0304_0506_0708,
        };
        let b = h.encode();
        assert_eq!(b.len(), 24);
        // Disposition C : klass @0, flags @4, root_tgid @8, owner_uid @12, tagged_ns @16.
        assert_eq!(u32::from_ne_bytes(b[0..4].try_into().unwrap()), 2);
        assert_eq!(u32::from_ne_bytes(b[8..12].try_into().unwrap()), 4242);
        assert_eq!(u64::from_ne_bytes(b[16..24].try_into().unwrap()), 0x0102_0304_0506_0708);
        assert_eq!(Hint::decode(&b), Some(h));
        assert_eq!(Hint::decode(&b[..20]), None);
        let mut bad = b;
        bad[0] = 9;
        assert_eq!(Hint::decode(&bad), None);
    }

    #[test]
    fn parse_requests() {
        assert_eq!(Request::parse("HELLO 1"), Ok(Request::Hello { version: 1 }));
        assert_eq!(Request::parse("TAG 1234\n".trim()), Ok(Request::Tag { pid: 1234 }));
        assert_eq!(Request::parse("TAGTID 77"), Ok(Request::TagThread { tid: 77 }));
        assert_eq!(Request::parse("UNTAG 9"), Ok(Request::Untag { pid: 9 }));
        assert_eq!(
            Request::parse("COMM dxvk-cs"),
            Ok(Request::Comm {
                pattern: "dxvk-cs".into()
            })
        );
        assert_eq!(Request::parse("LIST"), Ok(Request::List));
        assert_eq!(Request::parse("STATUS"), Ok(Request::Status));
        for r in [
            Request::Hello { version: 1 },
            Request::Tag { pid: 5 },
            Request::Comm {
                pattern: "RHIThread".into(),
            },
        ] {
            assert_eq!(Request::parse(&r.to_line()), Ok(r));
        }
    }

    #[test]
    fn reject_bad_requests() {
        for bad in [
            "",
            "TAG",
            "TAG -1",
            "TAG 0",
            "TAG abc",
            "TAG 1 2",
            "NOPE",
            "COMM",
            "COMM this-is-way-too-long",
        ] {
            let e = Request::parse(bad).unwrap_err();
            assert_eq!(e.code, ErrCode::Inval, "{bad:?}");
        }
        assert!(Request::parse(&"X".repeat(MAX_LINE + 1)).is_err());
    }

    #[test]
    fn error_line_is_single_line() {
        let e = ProtoError::new(ErrCode::Perm, "a\nb");
        assert_eq!(e.to_line(), "ERR EPERM a b");
    }

    #[test]
    fn list_entry_roundtrip() {
        let e = ListEntry {
            kind: "tgid".into(),
            id: 10,
            class: HintClass::Game,
            flags: F_INHERITED,
            root: 9,
            uid: 1000,
        };
        assert_eq!(ListEntry::parse(&e.to_line()), Some(e));
        assert_eq!(ListEntry::parse("HINT pid 1 game 0 0 0"), None);
    }

    #[test]
    fn kv_parsing() {
        let kv = parse_kv("proto=1 topo=x3d game=0-7,16-23");
        assert_eq!(kv[1], ("topo".into(), "x3d".into()));
        assert_eq!(kv[2].1, "0-7,16-23");
    }
}
