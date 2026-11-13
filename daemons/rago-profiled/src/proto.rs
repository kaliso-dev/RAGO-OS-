// SPDX-License-Identifier: GPL-2.0
//
// Protocole du socket /run/rago-profiled/profiled.sock : une requête JSON par
// ligne, une réponse JSON par ligne.
//
//   {"op":"apply","v":1,"query":{...},"label":"..."}   ouvre une session : le
//        profil du jeu est appliqué et le reste TANT QUE la connexion est
//        ouverte. {"op":"end"} (ou la fermeture du socket, même si le client
//        est tué) termine la session : le réglage de base revient.
//   {"op":"status"}                                    sessions actives
//   {"op":"prepare_switch","v":1,"query":{...}}        couche switch : écrit
//        le profil de sécurité Windows (hook M5/M6) avant le switch
//
// Le client ne peut que NOMMER un jeu : les profils viennent des dossiers
// root (/etc/rago/profiles, /usr/share/rago/profiles), jamais du client.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::profile::{Effective, Query};

pub const PROTO_VERSION: u32 = 1;
pub const DEFAULT_SOCKET: &str = "/run/rago-profiled/profiled.sock";
pub const DEFAULT_STATE_DIR: &str = "/run/rago-profiled";
/// Même groupe que le canal M0 : le joueur en fait déjà partie.
pub const DEFAULT_GROUP: &str = "rago";
pub const MAX_LINE: usize = 64 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    Apply {
        v: u32,
        query: Query,
        #[serde(default)]
        label: String,
    },
    End,
    Status,
    PrepareSwitch {
        v: u32,
        query: Query,
    },
}

/// Ce qui est arrivé à un réglage.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionStatus {
    /// Valeur écrite (et relue).
    Applied,
    /// Déjà à la bonne valeur.
    Unchanged,
    /// Réglage de base remis.
    Restored,
    /// Rien à faire / non applicable / non modifié volontairement.
    Skipped,
    /// Le module qui applique ce réglage n'existe pas encore (hook absent).
    Pending,
    Error,
    Info,
}

impl ActionStatus {
    pub fn label(&self) -> &'static str {
        match self {
            ActionStatus::Applied => "appliqué",
            ActionStatus::Unchanged => "déjà bon",
            ActionStatus::Restored => "base remise",
            ActionStatus::Skipped => "ignoré",
            ActionStatus::Pending => "en attente",
            ActionStatus::Error => "ERREUR",
            ActionStatus::Info => "info",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Action {
    pub knob: String,
    pub status: ActionStatus,
    pub detail: String,
}

impl Action {
    pub fn new(knob: &str, status: ActionStatus, detail: impl Into<String>) -> Self {
        Self {
            knob: knob.into(),
            status,
            detail: detail.into(),
        }
    }
}

impl fmt::Display for Action {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:<17} {:<12} {}", self.knob, self.status.label(), self.detail)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionInfo {
    pub session: u64,
    pub uid: u32,
    pub pid: u32,
    pub label: String,
    pub profile: String,
    /// Secondes depuis le début.
    pub age_s: u64,
    /// Seule la dernière session ouverte est appliquée.
    pub active: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Response {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<Effective>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<Action>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sessions: Vec<SessionInfo>,
    /// Réglages de base enregistrés (status).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<serde_json::Value>,
}

impl Response {
    pub fn err(msg: impl Into<String>) -> Self {
        Self {
            ok: false,
            error: Some(msg.into()),
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_format_is_stable() {
        let r = Request::Apply {
            v: 1,
            query: Query {
                id: Some("cs2".into()),
                ..Default::default()
            },
            label: "cs2".into(),
        };
        let j = serde_json::to_string(&r).unwrap();
        assert_eq!(j, r#"{"op":"apply","v":1,"query":{"id":"cs2"},"label":"cs2"}"#);
        assert_eq!(serde_json::from_str::<Request>(&j).unwrap(), r);
        assert_eq!(serde_json::to_string(&Request::End).unwrap(), r#"{"op":"end"}"#);
        assert!(serde_json::from_str::<Request>(r#"{"op":"rm -rf"}"#).is_err());
        let a = Action::new("thp", ActionStatus::Pending, "x");
        assert_eq!(
            serde_json::to_string(&a).unwrap(),
            r#"{"knob":"thp","status":"pending","detail":"x"}"#
        );
    }
}
