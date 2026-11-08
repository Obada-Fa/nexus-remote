//! SQLite-backed device and invitation store plus the `admin` CLI
//! (Utility Admin Contract v1, `docs/SPEC.md` §4 of nexus-utilities).
use rand::RngCore;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

pub const DEFAULT_PORT: u16 = 45679;
const MAX_ATTEMPTS: i64 = 5;
const LAST_SEEN_INTERVAL_MS: i64 = 60_000;

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as i64
}

pub fn data_dir() -> PathBuf {
    match std::env::var_os("NEXUS_REMOTE_DATA_DIR").filter(|v| !v.is_empty()) {
        Some(dir) => PathBuf::from(dir),
        None => dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("nexus-remote"),
    }
}

pub fn port() -> u16 {
    std::env::var("NEXUS_REMOTE_PORT")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .filter(|p| *p != 0)
        .unwrap_or(DEFAULT_PORT)
}

fn has_column(db: &Connection, table: &str, column: &str) -> rusqlite::Result<bool> {
    let mut stmt = db.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = stmt.query_map([], |r| r.get::<_, String>(1))?;
    for name in names {
        if name? == column {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Opens the database (creating directory, tables and additive migrations).
pub fn open_db(dir: &Path) -> rusqlite::Result<Connection> {
    std::fs::create_dir_all(dir).map_err(|e| {
        rusqlite::Error::ToSqlConversionFailure(Box::new(e))
    })?;
    let db = Connection::open(dir.join("companion.sqlite"))?;
    // Server and admin processes share the file: wait instead of failing.
    db.busy_timeout(Duration::from_millis(3000))?;
    let _ = db.pragma_update(None, "journal_mode", "WAL");
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY,name TEXT NOT NULL,hash TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0);
         CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY,state TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS invitations (id INTEGER PRIMARY KEY CHECK (id = 1),hash TEXT NOT NULL,invite_id TEXT NOT NULL,expires INTEGER NOT NULL,attempts INTEGER NOT NULL DEFAULT 0);",
    )?;
    for (column, ddl) in [
        ("invite_id", "ALTER TABLE devices ADD COLUMN invite_id TEXT"),
        ("last_seen", "ALTER TABLE devices ADD COLUMN last_seen INTEGER"),
        ("created_at", "ALTER TABLE devices ADD COLUMN created_at INTEGER"),
    ] {
        if !has_column(&db, "devices", column)? {
            db.execute(ddl, [])?;
        }
    }
    Ok(db)
}

pub fn host_id(db: &Connection) -> rusqlite::Result<String> {
    if let Some(id) = db
        .query_row("SELECT value FROM metadata WHERE key='host_id'", [], |r| {
            r.get(0)
        })
        .optional()?
    {
        return Ok(id);
    }
    let id = uuid::Uuid::new_v4().to_string();
    db.execute("INSERT OR IGNORE INTO metadata VALUES ('host_id',?1)", [&id])?;
    db.query_row("SELECT value FROM metadata WHERE key='host_id'", [], |r| {
        r.get(0)
    })
}

pub fn hash_code(code: &str) -> String {
    hex::encode(Sha256::digest(code.as_bytes()))
}

pub struct NewInvite {
    pub invite_id: String,
    pub secret: String,
    pub expires_at: i64,
}

/// Replaces the single open invitation.
pub fn create_invite(db: &Connection, ttl_secs: u64) -> rusqlite::Result<NewInvite> {
    let mut bytes = [0u8; 4];
    rand::rng().fill_bytes(&mut bytes);
    let secret = format!("{:08}", u32::from_be_bytes(bytes) % 100_000_000);
    let invite_id = uuid::Uuid::new_v4().to_string();
    let expires_at = now_ms() + (ttl_secs as i64) * 1000;
    db.execute(
        "INSERT OR REPLACE INTO invitations (id,hash,invite_id,expires,attempts) VALUES (1,?1,?2,?3,0)",
        params![hash_code(&secret), invite_id, expires_at],
    )?;
    Ok(NewInvite {
        invite_id,
        secret,
        expires_at,
    })
}

pub struct Paired {
    pub token: String,
}

#[derive(Debug)]
pub enum PairError {
    Invalid,
    Storage,
}

/// Verifies a code and, on success, consumes the invite and inserts the device atomically.
pub fn pair_device(db: &mut Connection, code: &str, name: &str) -> Result<Paired, PairError> {
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| PairError::Storage)?;
    let row: Option<(String, String, i64, i64)> = tx
        .query_row(
            "SELECT hash,invite_id,expires,attempts FROM invitations WHERE id=1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()
        .map_err(|_| PairError::Storage)?;
    let Some((hash, invite_id, expires, attempts)) = row else {
        return Err(PairError::Invalid);
    };
    if expires <= now_ms() || attempts >= MAX_ATTEMPTS {
        return Err(PairError::Invalid);
    }
    if hash != hash_code(code) {
        tx.execute("UPDATE invitations SET attempts=attempts+1 WHERE id=1", [])
            .map_err(|_| PairError::Storage)?;
        tx.commit().map_err(|_| PairError::Storage)?;
        return Err(PairError::Invalid);
    }
    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    let token = hex::encode(bytes);
    let id = uuid::Uuid::new_v4().to_string();
    let now = now_ms();
    tx.execute("DELETE FROM invitations WHERE id=1", [])
        .map_err(|_| PairError::Storage)?;
    tx.execute(
        "INSERT INTO devices (id,name,hash,invite_id,created_at,last_seen) VALUES (?1,?2,?3,?4,?5,?5)",
        params![id, name, hash_code(&token), invite_id, now],
    )
    .map_err(|_| PairError::Storage)?;
    tx.commit().map_err(|_| PairError::Storage)?;
    Ok(Paired { token })
}

fn touch(db: &Connection, id: &str) {
    let now = now_ms();
    let _ = db.execute(
        "UPDATE devices SET last_seen=?1 WHERE id=?2 AND (last_seen IS NULL OR last_seen<?3)",
        params![now, id, now - LAST_SEEN_INTERVAL_MS],
    );
}

/// Bearer token → device id. `revoked = 0` is required.
pub fn auth_token(db: &Connection, token: &str) -> Option<String> {
    let id: String = db
        .query_row(
            "SELECT id FROM devices WHERE hash=?1 AND revoked=0",
            [hash_code(token)],
            |r| r.get(0),
        )
        .ok()?;
    touch(db, &id);
    Some(id)
}

/// Device id still valid (not revoked)?
pub fn auth_device(db: &Connection, id: &str) -> bool {
    let ok = db
        .query_row("SELECT 1 FROM devices WHERE id=?1 AND revoked=0", [id], |_| {
            Ok(())
        })
        .is_ok();
    if ok {
        touch(db, id);
    }
    ok
}

// ---------------------------------------------------------------- CLI

type CliError = (&'static str, String);

fn fail(code: &'static str, message: impl Into<String>) -> CliError {
    (code, message.into())
}

fn internal(e: impl std::fmt::Display) -> CliError {
    fail("INTERNAL", e.to_string())
}

/// Runs the admin subcommand, prints exactly one JSON object, returns the exit code.
pub fn run(args: &[String]) -> i32 {
    let (out, code) = match execute(args) {
        Ok(mut value) => {
            value["contract"] = json!(1);
            (value, 0)
        }
        Err((code, message)) => (
            json!({"contract":1,"error":{"code":code,"message":message}}),
            1,
        ),
    };
    println!("{out}");
    code
}

fn execute(args: &[String]) -> Result<Value, CliError> {
    if !args.iter().any(|a| a == "--json") {
        return Err(fail("BAD_ARGS", "--json is required"));
    }
    let rest: Vec<&str> = args
        .iter()
        .map(String::as_str)
        .filter(|a| *a != "--json")
        .collect();
    let Some((&sub, rest)) = rest.split_first() else {
        return Err(fail(
            "BAD_ARGS",
            "usage: admin <status|invite|devices|revoke> --json",
        ));
    };
    match sub {
        "status" | "devices" => {
            if !rest.is_empty() {
                return Err(fail("BAD_ARGS", format!("unexpected argument: {}", rest[0])));
            }
            let dir = data_dir();
            let db = open_db(&dir).map_err(|e| fail("UNAVAILABLE", e.to_string()))?;
            if sub == "status" {
                status(&db, &dir)
            } else {
                devices(&db)
            }
        }
        "invite" => invite(rest),
        "revoke" => revoke(rest),
        other => Err(fail("BAD_ARGS", format!("unknown subcommand: {other}"))),
    }
}

fn status(db: &Connection, dir: &Path) -> Result<Value, CliError> {
    let host = host_id(db).map_err(internal)?;
    let (_, _, fingerprint) = crate::tls_identity(&dir.to_path_buf()).map_err(internal)?;
    let devices: i64 = db
        .query_row("SELECT COUNT(*) FROM devices WHERE revoked=0", [], |r| {
            r.get(0)
        })
        .map_err(internal)?;
    Ok(json!({
        "utility":"remote",
        "version":env!("CARGO_PKG_VERSION"),
        "hostId":host,
        "devices":devices,
        "fingerprint":fingerprint,
    }))
}

fn invite(rest: &[&str]) -> Result<Value, CliError> {
    let mut ttl: Option<u64> = None;
    let mut label: Option<&str> = None;
    let mut it = rest.iter();
    while let Some(&arg) = it.next() {
        match arg {
            "--ttl" => {
                let v = it
                    .next()
                    .ok_or_else(|| fail("BAD_ARGS", "--ttl needs a value"))?;
                ttl = Some(
                    v.parse()
                        .map_err(|_| fail("BAD_ARGS", "--ttl must be a whole number of seconds"))?,
                );
            }
            "--label" => {
                label = Some(
                    it.next()
                        .ok_or_else(|| fail("BAD_ARGS", "--label needs a value"))?,
                );
            }
            other => return Err(fail("BAD_ARGS", format!("unexpected argument: {other}"))),
        }
    }
    // The label is accepted for contract compatibility; the phone supplies the stored device name.
    let _ = label;
    let ttl = ttl.ok_or_else(|| fail("BAD_ARGS", "--ttl is required"))?;
    if !(60..=900).contains(&ttl) {
        return Err(fail("BAD_ARGS", "--ttl must be between 60 and 900 seconds"));
    }
    let dir = data_dir();
    let db = open_db(&dir).map_err(|e| fail("UNAVAILABLE", e.to_string()))?;
    let host = host_id(&db).map_err(internal)?;
    let (_, _, fingerprint) = crate::tls_identity(&dir.to_path_buf()).map_err(internal)?;
    let invite = create_invite(&db, ttl).map_err(internal)?;
    Ok(json!({
        "inviteId":invite.invite_id,
        "secret":invite.secret,
        "expiresAt":invite.expires_at,
        "fingerprint":fingerprint,
        "hostId":host,
    }))
}

fn devices(db: &Connection) -> Result<Value, CliError> {
    let mut stmt = db
        .prepare(
            "SELECT id,name,created_at,last_seen,invite_id FROM devices WHERE revoked=0 ORDER BY COALESCE(created_at,0),rowid",
        )
        .map_err(internal)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(json!({
                "id":r.get::<_,String>(0)?,
                "name":r.get::<_,String>(1)?,
                "createdAt":r.get::<_,Option<i64>>(2)?.unwrap_or(0),
                "lastSeenAt":r.get::<_,Option<i64>>(3)?,
                "inviteId":r.get::<_,Option<String>>(4)?,
            }))
        })
        .map_err(internal)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(internal)?;
    Ok(json!({"devices":rows}))
}

fn revoke(rest: &[&str]) -> Result<Value, CliError> {
    let [id] = rest else {
        return Err(fail("BAD_ARGS", "usage: admin revoke <deviceId> --json"));
    };
    let dir = data_dir();
    let db = open_db(&dir).map_err(|e| fail("UNAVAILABLE", e.to_string()))?;
    let changed = db
        .execute("UPDATE devices SET revoked=1 WHERE id=?1 AND revoked=0", [id])
        .map_err(internal)?;
    if changed == 0 {
        return Err(fail("NOT_FOUND", format!("no active device with id {id}")));
    }
    Ok(json!({"revoked":true}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> Connection {
        let dir = std::env::temp_dir().join(format!("nexus-remote-unit-{}", uuid::Uuid::new_v4()));
        open_db(&dir).unwrap()
    }

    #[test]
    fn invite_is_single_use_and_replaced_by_a_new_one() {
        let mut db = db();
        let first = create_invite(&db, 60).unwrap();
        let second = create_invite(&db, 60).unwrap();
        assert!(pair_device(&mut db, &first.secret, "a").is_err() || first.secret == second.secret);
        let paired = pair_device(&mut db, &second.secret, "phone").unwrap();
        assert!(pair_device(&mut db, &second.secret, "again").is_err());
        let invite: Option<String> = db
            .query_row("SELECT invite_id FROM devices", [], |r| r.get(0))
            .unwrap();
        assert_eq!(invite.as_deref(), Some(second.invite_id.as_str()));
        assert!(auth_token(&db, &paired.token).is_some());
    }

    #[test]
    fn five_wrong_attempts_kill_the_invite() {
        let mut db = db();
        let invite = create_invite(&db, 60).unwrap();
        let wrong = if invite.secret == "00000000" { "11111111" } else { "00000000" };
        for _ in 0..5 {
            assert!(pair_device(&mut db, wrong, "p").is_err());
        }
        assert!(pair_device(&mut db, &invite.secret, "p").is_err());
    }

    #[test]
    fn revoked_device_fails_auth_and_last_seen_is_throttled() {
        let mut db = db();
        let invite = create_invite(&db, 60).unwrap();
        let paired = pair_device(&mut db, &invite.secret, "p").unwrap();
        let id = auth_token(&db, &paired.token).unwrap();
        db.execute("UPDATE devices SET last_seen=1000 WHERE id=?1", [&id]).unwrap();
        assert!(auth_device(&db, &id));
        let seen: i64 = db.query_row("SELECT last_seen FROM devices", [], |r| r.get(0)).unwrap();
        assert!(seen > 1000);
        let before = seen;
        assert!(auth_device(&db, &id));
        let after: i64 = db.query_row("SELECT last_seen FROM devices", [], |r| r.get(0)).unwrap();
        assert_eq!(before, after);
        db.execute("UPDATE devices SET revoked=1", []).unwrap();
        assert!(!auth_device(&db, &id));
        assert!(auth_token(&db, &paired.token).is_none());
    }
}
