// SPDX-License-Identifier: GPL-2.0
//
// Client du canal launcher -> scx_rago (utilisé par rago-sched-hint).

use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use crate::cpuset::CpuSet;
use crate::proto::{self, ErrCode, ListEntry, ProtoError, Request};
use crate::topology::TopologyKind;
use crate::PROTO_VERSION;

#[derive(Debug)]
pub enum ClientError {
    /// Socket absent ou refusé : scx_rago ne tourne pas (ou droits manquants).
    Unavailable(io::Error),
    /// Erreur renvoyée par le serveur.
    Server(ProtoError),
    /// Réponse illisible ou coupure.
    Protocol(String),
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClientError::Unavailable(e) => write!(f, "scx_rago injoignable : {e}"),
            ClientError::Server(e) => write!(f, "refusé par scx_rago : {e}"),
            ClientError::Protocol(m) => write!(f, "réponse invalide de scx_rago : {m}"),
        }
    }
}

impl std::error::Error for ClientError {}

impl From<ProtoError> for ClientError {
    fn from(e: ProtoError) -> Self {
        ClientError::Server(e)
    }
}

/// Infos renvoyées par HELLO.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HelloInfo {
    pub abi: u32,
    pub topo: TopologyKind,
    pub game: CpuSet,
    pub bg: CpuSet,
    pub confine: bool,
}

pub struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
}

fn parse_set(v: &str) -> Result<CpuSet, ClientError> {
    if v == "-" {
        return Ok(CpuSet::new());
    }
    CpuSet::parse(v).map_err(|e| ClientError::Protocol(e.to_string()))
}

impl Client {
    pub fn connect(path: &Path) -> Result<Self, ClientError> {
        let s = UnixStream::connect(path).map_err(ClientError::Unavailable)?;
        s.set_read_timeout(Some(Duration::from_secs(3)))
            .map_err(ClientError::Unavailable)?;
        s.set_write_timeout(Some(Duration::from_secs(3)))
            .map_err(ClientError::Unavailable)?;
        let writer = s.try_clone().map_err(ClientError::Unavailable)?;
        Ok(Self {
            reader: BufReader::new(s),
            writer,
        })
    }

    /// Envoie une requête ; renvoie (lignes de données, contenu après « OK »).
    pub fn call(&mut self, req: &Request) -> Result<(Vec<String>, String), ClientError> {
        let line = format!("{}\n", req.to_line());
        self.writer
            .write_all(line.as_bytes())
            .map_err(|e| ClientError::Protocol(e.to_string()))?;
        let mut data = Vec::new();
        loop {
            let mut l = String::new();
            let n = self
                .reader
                .read_line(&mut l)
                .map_err(|e| ClientError::Protocol(e.to_string()))?;
            if n == 0 {
                return Err(ClientError::Protocol("connexion fermée".into()));
            }
            let l = l.trim_end().to_string();
            if l == "OK" || l.starts_with("OK ") {
                return Ok((data, l.get(3..).unwrap_or("").to_string()));
            }
            if let Some(rest) = l.strip_prefix("ERR ") {
                let (code, msg) = rest.split_once(' ').unwrap_or((rest, ""));
                let code = ErrCode::parse(code)
                    .ok_or_else(|| ClientError::Protocol(format!("code inconnu : {code}")))?;
                return Err(ClientError::Server(ProtoError::new(code, msg)));
            }
            data.push(l);
        }
    }

    pub fn hello(&mut self) -> Result<HelloInfo, ClientError> {
        let (_, ok) = self.call(&Request::Hello {
            version: PROTO_VERSION,
        })?;
        let kv = proto::parse_kv(&ok);
        let get = |k: &str| {
            kv.iter()
                .find(|(kk, _)| kk == k)
                .map(|(_, v)| v.as_str())
                .ok_or_else(|| ClientError::Protocol(format!("champ {k} absent de HELLO")))
        };
        Ok(HelloInfo {
            abi: get("abi")?
                .parse()
                .map_err(|_| ClientError::Protocol("abi".into()))?,
            topo: TopologyKind::parse(get("topo")?)
                .ok_or_else(|| ClientError::Protocol("topo".into()))?,
            game: parse_set(get("game")?)?,
            bg: parse_set(get("bg")?)?,
            confine: get("confine")? == "1",
        })
    }

    pub fn tag(&mut self, pid: u32) -> Result<String, ClientError> {
        Ok(self.call(&Request::Tag { pid })?.1)
    }

    pub fn tag_thread(&mut self, tid: u32) -> Result<String, ClientError> {
        Ok(self.call(&Request::TagThread { tid })?.1)
    }

    pub fn untag(&mut self, pid: u32) -> Result<String, ClientError> {
        Ok(self.call(&Request::Untag { pid })?.1)
    }

    pub fn comm(&mut self, pattern: &str) -> Result<String, ClientError> {
        Ok(self
            .call(&Request::Comm {
                pattern: pattern.to_string(),
            })?
            .1)
    }

    pub fn list(&mut self) -> Result<Vec<ListEntry>, ClientError> {
        let (data, _) = self.call(&Request::List)?;
        data.iter()
            .map(|l| {
                ListEntry::parse(l).ok_or_else(|| ClientError::Protocol(format!("ligne LIST : {l}")))
            })
            .collect()
    }

    pub fn status(&mut self) -> Result<Vec<(String, String)>, ClientError> {
        let (_, ok) = self.call(&Request::Status)?;
        Ok(proto::parse_kv(&ok))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::{self, MemorySink, ServerConfig, ServerState};
    use crate::topology::Topology;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};

    /// Bout en bout sur un vrai socket : serveur + client, sur le vrai /proc.
    #[test]
    fn end_to_end_over_unix_socket() {
        let d = tempfile::tempdir().unwrap();
        let sock = d.path().join("run/rago/sched-hint.sock");
        let topo = Topology::manual(
            TopologyKind::Hybrid,
            CpuSet::parse("0-3").unwrap(),
            CpuSet::parse("0-1").unwrap(),
            None,
        )
        .unwrap();
        let state = Arc::new(ServerState::new(
            topo,
            false,
            vec!["RenderThread".into()],
            ServerConfig::default(),
        ));
        let sink = Arc::new(Mutex::new(MemorySink::default()));
        state.install_sink(Box::new(sink.clone())).unwrap();
        let (listener, warn) = server::bind(&sock, None).unwrap();
        assert!(warn.is_none());
        let stop = Arc::new(AtomicBool::new(false));
        let (st, sp) = (state.clone(), stop.clone());
        let th = std::thread::spawn(move || server::serve(listener, st, sp));

        let mut c = Client::connect(&sock).unwrap();
        let h = c.hello().unwrap();
        assert_eq!(h.topo, TopologyKind::Hybrid);
        assert_eq!(h.game.to_string(), "0-1");
        assert_eq!(h.bg.to_string(), "2-3");
        assert!(!h.confine);

        let me = std::process::id();
        let ok = c.tag(me).unwrap();
        assert!(ok.contains(&format!("pid={me}")), "{ok}");
        assert_eq!(sink.lock().unwrap().tgids[&me].owner_uid, unsafe {
            libc::getuid()
        });
        let l = c.list().unwrap();
        assert!(l.iter().any(|e| e.id == me && e.kind == "tgid"));
        c.comm("FrameThread").unwrap();
        assert!(sink.lock().unwrap().comms.contains(&"FrameThread".to_string()));
        let st = c.status().unwrap();
        assert!(st.iter().any(|(k, v)| k == "maps" && v == "ready"));
        assert!(matches!(
            c.call(&Request::Hello { version: 99 }),
            Err(ClientError::Server(e)) if e.code == ErrCode::Version
        ));
        c.untag(me).unwrap();
        assert!(sink.lock().unwrap().tgids.is_empty());
        assert!(matches!(c.untag(me), Err(ClientError::Server(e)) if e.code == ErrCode::Srch));

        stop.store(true, Ordering::Relaxed);
        th.join().unwrap();
    }

    #[test]
    fn missing_socket_is_unavailable() {
        let d = tempfile::tempdir().unwrap();
        assert!(matches!(
            Client::connect(&d.path().join("nope.sock")),
            Err(ClientError::Unavailable(_))
        ));
    }
}
