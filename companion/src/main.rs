use axum::{
    Json, Router,
    body::Bytes,
    extract::{
        DefaultBodyLimit, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
};
use futures_util::StreamExt;
use rand::RngCore;
use rusqlite::{Connection, params};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, oneshot};
use x11rb::{
    connection::Connection as _,
    protocol::{
        xproto::{ConnectionExt as _, Window},
        xtest,
    },
    rust_connection::RustConnection,
};

const PORT: u16 = 45679;
mod media;
mod speech;
use speech::SpeechService;
type ResultJson = Result<Value, (&'static str, &'static str)>;
#[derive(Clone)]
struct App {
    db: Arc<Mutex<Connection>>,
    invitation: Arc<Mutex<Invitation>>,
    lease: Arc<Mutex<Option<Lease>>>,
    desktop: mpsc::Sender<(DesktopCommand, oneshot::Sender<Result<(), String>>)>,
    speech: SpeechService,
    x11_session: bool,
}
struct Invitation {
    code: String,
    until: Instant,
    attempts: u8,
}
struct Lease {
    owner: String,
    heartbeat: Instant,
}
#[derive(Deserialize)]
struct PairRequest {
    code: String,
    device_name: String,
}
#[derive(Deserialize)]
struct Request {
    version: u32,
    id: String,
    method: String,
    params: Value,
}
enum DesktopCommand {
    Move(i32, i32),
    Scroll(i32, i32),
    Button(u8, bool),
    Key(String),
    Release,
    Insert(String),
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory = dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("nexus-remote");
    std::fs::create_dir_all(&directory)?;
    let db = Connection::open(directory.join("companion.sqlite"))?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL);
       CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY,name TEXT NOT NULL,hash TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0);
       CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY,state TEXT NOT NULL);")?;
    let host_id: String = db
        .query_row("SELECT value FROM metadata WHERE key='host_id'", [], |r| {
            r.get(0)
        })
        .unwrap_or_else(|_| {
            let id = uuid::Uuid::new_v4().to_string();
            db.execute("INSERT INTO metadata VALUES ('host_id',?1)", [&id])
                .expect("save host ID");
            id
        });
    let (certificate, key, fingerprint) = tls_identity(&directory)?;
    let mut bytes = [0u8; 4];
    rand::rng().fill_bytes(&mut bytes);
    let code = format!("{:08}", u32::from_be_bytes(bytes) % 100_000_000);
    let (tx, rx) = mpsc::channel(256);
    let x11_session = std::env::var("XDG_SESSION_TYPE").unwrap_or_default() != "wayland"
        && std::env::var_os("DISPLAY").is_some();
    if x11_session {
        std::thread::spawn(move || desktop_loop(rx));
    }
    let speech = SpeechService::new(directory.join("audio"))?;
    let app = App {
        db: Arc::new(Mutex::new(db)),
        invitation: Arc::new(Mutex::new(Invitation {
            code: code.clone(),
            until: Instant::now() + Duration::from_secs(900),
            attempts: 0,
        })),
        lease: Arc::new(Mutex::new(None)),
        desktop: tx,
        speech,
        x11_session,
    };
    let watchdog = app.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_millis(250));
        loop {
            tick.tick().await;
            let expired = {
                let mut l = watchdog.lease.lock().unwrap();
                if l.as_ref()
                    .is_some_and(|l| l.heartbeat.elapsed() > Duration::from_secs(3))
                {
                    *l = None;
                    true
                } else {
                    false
                }
            };
            if expired {
                let _ = dispatch(&watchdog, DesktopCommand::Release).await;
            }
        }
    });
    let router = Router::new()
        .route("/pair", post(pair))
        .route("/ws", get(ws))
        .route(
            "/transcribe",
            post(transcribe).layer(DefaultBodyLimit::max(10 * 1024 * 1024)),
        )
        .route("/health", get(|| async { "ok" }))
        .with_state(app);
    println!("Host ID: {host_id}");
    println!("Address: https://<computer-address>:{PORT}");
    println!("TLS SHA-256 fingerprint: {fingerprint}");
    println!("Pairing code: {code}");
    let tls = axum_server::tls_rustls::RustlsConfig::from_pem(certificate, key).await?;
    axum_server::bind_rustls(([0, 0, 0, 0], PORT).into(), tls)
        .serve(router.into_make_service())
        .await?;
    Ok(())
}

fn tls_identity(path: &PathBuf) -> Result<(Vec<u8>, Vec<u8>, String), Box<dyn std::error::Error>> {
    let cert_path = path.join("identity.pem");
    let key_path = path.join("identity-key.pem");
    if !cert_path.exists() || !key_path.exists() {
        let issued = rcgen::generate_simple_self_signed(vec!["nexus-remote.local".into()])?;
        std::fs::write(&cert_path, issued.cert.pem())?;
        std::fs::write(&key_path, issued.signing_key.serialize_pem())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&key_path, std::fs::Permissions::from_mode(0o600))?;
        }
    }
    let cert = std::fs::read(&cert_path)?;
    let key = std::fs::read(&key_path)?;
    use base64::Engine as _;
    let body: String = std::str::from_utf8(&cert)?
        .lines()
        .filter(|l| !l.starts_with("-----"))
        .collect();
    let der = base64::engine::general_purpose::STANDARD.decode(body)?;
    Ok((cert, key, hex::encode_upper(Sha256::digest(der))))
}

async fn pair(State(app): State<App>, Json(request): Json<PairRequest>) -> impl IntoResponse {
    if request.device_name.trim().is_empty() || request.device_name.len() > 100 {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"Invalid device name"})),
        )
            .into_response();
    }
    let allowed = {
        let mut i = app.invitation.lock().unwrap();
        let allowed = i.until > Instant::now() && i.attempts < 5 && i.code == request.code;
        if allowed {
            i.until = Instant::now();
        } else {
            i.attempts = i.attempts.saturating_add(1);
        }
        allowed
    };
    if !allowed {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({"error":"Invalid or expired pairing code"})),
        )
            .into_response();
    }
    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    let token = hex::encode(bytes);
    let hash = hex::encode(Sha256::digest(token.as_bytes()));
    let id = uuid::Uuid::new_v4().to_string();
    let host_id = {
        let db = app.db.lock().unwrap();
        if db
            .execute(
                "INSERT INTO devices (id,name,hash) VALUES (?1,?2,?3)",
                params![id, request.device_name, hash],
            )
            .is_err()
        {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error":"Could not save device"})),
            )
                .into_response();
        }
        db.query_row("SELECT value FROM metadata WHERE key='host_id'", [], |r| {
            r.get::<_, String>(0)
        })
        .unwrap_or_default()
    };
    (
        StatusCode::OK,
        Json(json!({"token":token,"host_id":host_id})),
    )
        .into_response()
}

async fn ws(
    State(app): State<App>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> impl IntoResponse {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    let Some(device) = token.and_then(|t| authenticated(&app, t)) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    upgrade
        .on_upgrade(move |socket| socket_loop(app, device, socket))
        .into_response()
}
async fn transcribe(State(app): State<App>, headers: HeaderMap, body: Bytes) -> impl IntoResponse {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    let Some(device) = token.and_then(|t| authenticated(&app, t)) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"unauthorized"})),
        )
            .into_response();
    };
    let job_id = headers
        .get("x-job-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let language = headers
        .get("x-language")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("auto");
    let expected = headers
        .get("x-content-sha256")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let actual = hex::encode(Sha256::digest(&body));
    if expected != actual {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"checksum_mismatch"})),
        )
            .into_response();
    }
    match app
        .speech
        .transcribe(&device, job_id, language, &body)
        .await
    {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(code) => {
            let status = if code == "busy" {
                StatusCode::CONFLICT
            } else if code == "model_missing" {
                StatusCode::SERVICE_UNAVAILABLE
            } else {
                StatusCode::BAD_REQUEST
            };
            (status, Json(json!({"error":code}))).into_response()
        }
    }
}
fn authenticated(app: &App, token: &str) -> Option<String> {
    let hash = hex::encode(Sha256::digest(token.as_bytes()));
    app.db
        .lock()
        .unwrap()
        .query_row(
            "SELECT id FROM devices WHERE hash=?1 AND revoked=0",
            [hash],
            |r| r.get(0),
        )
        .ok()
}
async fn socket_loop(app: App, device: String, mut socket: WebSocket) {
    while let Some(message) = socket.next().await {
        let Ok(Message::Text(text)) = message else {
            continue;
        };
        if authenticated_device(&app, &device).is_none() {
            break;
        }
        if text.len() > 512 * 1024 {
            break;
        }
        let reply = match serde_json::from_str::<Request>(&text) {
            Ok(req) => {
                let id = req.id.clone();
                let result = if req.version == 1 && !id.is_empty() && id.len() <= 64 {
                    process(&app, &device, &req.method, req.params).await
                } else {
                    Err(("invalid_request", "Unsupported version or request ID"))
                };
                match result {
                    Ok(value) => json!({"version":1,"id":id,"result":value}),
                    Err((code, message)) => {
                        json!({"version":1,"id":id,"error":{"code":code,"message":message}})
                    }
                }
            }
            Err(_) => {
                json!({"version":1,"id":"","error":{"code":"invalid_request","message":"Invalid JSON"}})
            }
        };
        if socket
            .send(Message::Text(reply.to_string().into()))
            .await
            .is_err()
        {
            break;
        }
    }
    let owned = {
        let mut l = app.lease.lock().unwrap();
        if l.as_ref().is_some_and(|l| l.owner == device) {
            *l = None;
            true
        } else {
            false
        }
    };
    if owned {
        let _ = dispatch(&app, DesktopCommand::Release).await;
    }
}
fn authenticated_device(app: &App, device: &str) -> Option<String> {
    app.db
        .lock()
        .unwrap()
        .query_row(
            "SELECT id FROM devices WHERE id=?1 AND revoked=0",
            [device],
            |r| r.get(0),
        )
        .ok()
}

async fn process(app: &App, device: &str, method: &str, p: Value) -> ResultJson {
    if method == "host.info" {
        return Ok(json!({"name":"Nexus Remote",
        "platform":if cfg!(target_os="windows"){"windows"}else if app.x11_session{"linux-x11"}else{"linux-wayland"},
        "capabilities":{"input":if app.x11_session{"supported"}else{"unsupported"},
        "clipboard":if app.x11_session{"supported"}else{"unsupported"},
        "speech":if app.speech.available(){"supported"}else{"temporarily_unavailable"},
        "media":if media::available(){"supported"}else{"temporarily_unavailable"}}}));
    }
    if method == "media.list" {
        return media::players()
            .await
            .map_err(|code| (code, "Could not list media players"));
    }
    if method == "volume.state" {
        return media::volume_state()
            .await
            .map_err(|code| (code, "Could not read system volume"));
    }
    if method == "controller.acquire" {
        let mut l = app.lease.lock().unwrap();
        if l.as_ref()
            .is_some_and(|x| x.owner != device && x.heartbeat.elapsed() < Duration::from_secs(3))
        {
            return Err(("busy", "Another device is controlling this computer"));
        }
        *l = Some(Lease {
            owner: device.into(),
            heartbeat: Instant::now(),
        });
        return Ok(json!({"acquired":true}));
    }
    if method == "controller.heartbeat" {
        let mut l = app.lease.lock().unwrap();
        if let Some(l) = l.as_mut().filter(|l| l.owner == device) {
            l.heartbeat = Instant::now();
            return Ok(json!({}));
        }
        return Err(("lease_required", "Control lease expired"));
    }
    if method == "controller.release" {
        let owned = {
            let mut l = app.lease.lock().unwrap();
            if l.as_ref().is_some_and(|l| l.owner == device) {
                *l = None;
                true
            } else {
                false
            }
        };
        if owned {
            dispatch(app, DesktopCommand::Release).await?;
        }
        return Ok(json!({}));
    }
    if method == "text.status" {
        let id = string(&p, "operation_id")?;
        let status: Option<String> = app
            .db
            .lock()
            .unwrap()
            .query_row("SELECT state FROM receipts WHERE id=?1", [id], |r| r.get(0))
            .ok();
        return Ok(json!({"status":status.unwrap_or_else(||"rejected".into())}));
    }
    if !app
        .lease
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|l| l.owner == device && l.heartbeat.elapsed() < Duration::from_secs(3))
    {
        return Err(("lease_required", "Acquire control first"));
    }
    if !app.x11_session && (method.starts_with("input.") || method == "text.insert") {
        return Err((
            "unsupported",
            "Desktop input is not available in this session",
        ));
    }
    let command = match method {
        "input.move" => DesktopCommand::Move(
            number(&p, "dx", -1000, 1000)?,
            number(&p, "dy", -1000, 1000)?,
        ),
        "input.scroll" => {
            DesktopCommand::Scroll(number(&p, "dx", -20, 20)?, number(&p, "dy", -20, 20)?)
        }
        "input.button" => DesktopCommand::Button(
            number(&p, "button", 1, 3)? as u8,
            p.get("down")
                .and_then(Value::as_bool)
                .ok_or(("invalid_params", "Missing button state"))?,
        ),
        "input.key" => DesktopCommand::Key(string(&p, "key")?.into()),
        "input.release_all" => DesktopCommand::Release,
        "media.action" => {
            let player = string(&p, "player_id")?;
            let action = string(&p, "action")?;
            return media::action(player, action)
                .await
                .map_err(|code| (code, "Media action failed"));
        }
        "media.seek" => {
            let player = string(&p, "player_id")?;
            let seconds = number(&p, "seconds", 0, 86400)?;
            return media::seek(player, seconds)
                .await
                .map_err(|code| (code, "Could not seek player"));
        }
        "volume.set" => {
            let percent = number(&p, "percent", 0, 100)?;
            return media::set_volume(percent)
                .await
                .map_err(|code| (code, "Could not set system volume"));
        }
        "volume.mute" => {
            let muted = p
                .get("muted")
                .and_then(Value::as_bool)
                .ok_or(("invalid_params", "Missing mute state"))?;
            return media::set_mute(muted)
                .await
                .map_err(|code| (code, "Could not change mute state"));
        }
        "text.insert" => {
            let text = string(&p, "text")?;
            let id = string(&p, "operation_id")?;
            if text.len() > 65536 || text.contains('\0') || id.len() > 64 {
                return Err(("invalid_params", "Text exceeds the limit"));
            }
            let db = app.db.lock().unwrap();
            if let Ok(status) = db.query_row("SELECT state FROM receipts WHERE id=?1", [id], |r| {
                r.get::<_, String>(0)
            }) {
                return Ok(json!({"status":status}));
            }
            db.execute(
                "INSERT INTO receipts (id,state) VALUES (?1,'unknown')",
                [id],
            )
            .map_err(|_| ("storage_error", "Could not record operation"))?;
            DesktopCommand::Insert(text.into())
        }
        _ => return Err(("unknown_method", "Unknown command")),
    };
    dispatch(app, command).await?;
    if method == "text.insert" {
        let id = string(&p, "operation_id")?;
        app.db
            .lock()
            .unwrap()
            .execute(
                "UPDATE receipts SET state='paste_dispatched' WHERE id=?1",
                [id],
            )
            .map_err(|_| ("storage_error", "Could not save receipt"))?;
        Ok(json!({"status":"paste_dispatched"}))
    } else {
        Ok(json!({}))
    }
}
fn string<'a>(p: &'a Value, key: &str) -> Result<&'a str, (&'static str, &'static str)> {
    p.get(key)
        .and_then(Value::as_str)
        .ok_or(("invalid_params", "Missing string parameter"))
}
fn number(p: &Value, key: &str, min: i32, max: i32) -> Result<i32, (&'static str, &'static str)> {
    let value = p
        .get(key)
        .and_then(Value::as_i64)
        .ok_or(("invalid_params", "Missing number"))?;
    if value < min as i64 || value > max as i64 {
        return Err(("invalid_params", "Number out of range"));
    }
    Ok(value as i32)
}
async fn dispatch(app: &App, command: DesktopCommand) -> Result<(), (&'static str, &'static str)> {
    let (tx, rx) = oneshot::channel();
    app.desktop
        .send((command, tx))
        .await
        .map_err(|_| ("desktop_unavailable", "Desktop session unavailable"))?;
    rx.await
        .map_err(|_| ("desktop_unavailable", "Desktop session unavailable"))?
        .map_err(|_| ("desktop_error", "Desktop command failed"))
}

fn desktop_loop(mut rx: mpsc::Receiver<(DesktopCommand, oneshot::Sender<Result<(), String>>)>) {
    let Ok((conn, screen)) = RustConnection::connect(None) else {
        eprintln!("X11 session unavailable");
        return;
    };
    let root = conn.setup().roots[screen].root;
    let mut clipboard = arboard::Clipboard::new().ok();
    let mut held = [false; 4];
    while let Some((command, response)) = rx.blocking_recv() {
        let result = desktop_command(&conn, root, &mut clipboard, &mut held, command)
            .map_err(|e| e.to_string());
        let _ = response.send(result);
    }
}
fn desktop_command(
    conn: &RustConnection,
    root: Window,
    clipboard: &mut Option<arboard::Clipboard>,
    held: &mut [bool; 4],
    command: DesktopCommand,
) -> Result<(), Box<dyn std::error::Error>> {
    match command {
        DesktopCommand::Move(dx, dy) => {
            let pointer = conn.query_pointer(root)?.reply()?;
            xtest::fake_input(
                conn,
                6,
                0,
                0,
                root,
                pointer.root_x.saturating_add(dx as i16),
                pointer.root_y.saturating_add(dy as i16),
                0,
            )?;
        }
        DesktopCommand::Scroll(dx, dy) => {
            for _ in 0..dy.unsigned_abs() {
                let button = if dy > 0 { 5 } else { 4 };
                button_event(conn, root, button, true)?;
                button_event(conn, root, button, false)?;
            }
            for _ in 0..dx.unsigned_abs() {
                let button = if dx > 0 { 7 } else { 6 };
                button_event(conn, root, button, true)?;
                button_event(conn, root, button, false)?;
            }
        }
        DesktopCommand::Button(button, down) => {
            button_event(conn, root, button, down)?;
            held[button as usize] = down;
        }
        DesktopCommand::Key(key) => {
            key_chord(conn, root, &key)?;
        }
        DesktopCommand::Release => {
            for button in 1..=3 {
                if held[button] {
                    button_event(conn, root, button as u8, false)?;
                    held[button] = false;
                }
            }
        }
        DesktopCommand::Insert(text) => {
            clipboard
                .as_mut()
                .ok_or("Clipboard unavailable")?
                .set_text(text)?;
            key_chord(conn, root, "Paste")?;
        }
    }
    conn.flush()?;
    Ok(())
}
fn button_event(
    conn: &RustConnection,
    root: Window,
    button: u8,
    down: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    xtest::fake_input(conn, if down { 4 } else { 5 }, button, 0, root, 0, 0, 0)?;
    Ok(())
}
fn key_chord(
    conn: &RustConnection,
    root: Window,
    key: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let (ctrl, shift, symbol): (bool, bool, u32) = match key {
        "Escape" => (false, false, 0xff1b),
        "Tab" => (false, false, 0xff09),
        "Enter" => (false, false, 0xff0d),
        "Left" => (false, false, 0xff51),
        "Up" => (false, false, 0xff52),
        "Right" => (false, false, 0xff53),
        "Down" => (false, false, 0xff54),
        "Copy" => (true, false, 0x63),
        "Paste" => (true, false, 0x76),
        "TerminalPaste" => (true, true, 0x76),
        _ => return Err("Unsupported key".into()),
    };
    let code = keycode(conn, symbol)?;
    let control = if ctrl {
        Some(keycode(conn, 0xffe3)?)
    } else {
        None
    };
    let shift_code = if shift {
        Some(keycode(conn, 0xffe1)?)
    } else {
        None
    };
    if let Some(control) = control {
        xtest::fake_input(conn, 2, control, 0, root, 0, 0, 0)?;
    }
    if let Some(shift) = shift_code {
        xtest::fake_input(conn, 2, shift, 0, root, 0, 0, 0)?;
    }
    xtest::fake_input(conn, 2, code, 0, root, 0, 0, 0)?;
    xtest::fake_input(conn, 3, code, 0, root, 0, 0, 0)?;
    if let Some(shift) = shift_code {
        xtest::fake_input(conn, 3, shift, 0, root, 0, 0, 0)?;
    }
    if let Some(control) = control {
        xtest::fake_input(conn, 3, control, 0, root, 0, 0, 0)?;
    }
    Ok(())
}
fn keycode(conn: &RustConnection, symbol: u32) -> Result<u8, Box<dyn std::error::Error>> {
    let setup = conn.setup();
    let first = setup.min_keycode;
    let count = setup.max_keycode - first + 1;
    let map = conn.get_keyboard_mapping(first, count)?.reply()?;
    for (index, group) in map
        .keysyms
        .chunks(map.keysyms_per_keycode as usize)
        .enumerate()
    {
        if group.contains(&symbol) {
            return Ok(first + index as u8);
        }
    }
    Err("Key unavailable in desktop layout".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[tokio::test]
    async fn insertion_id_is_dispatched_once_and_unknown_is_not_retried() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE receipts (id TEXT PRIMARY KEY,state TEXT NOT NULL);")
            .unwrap();
        let (tx, mut rx) =
            mpsc::channel::<(DesktopCommand, oneshot::Sender<Result<(), String>>)>(8);
        let dispatches = Arc::new(AtomicUsize::new(0));
        let observed = dispatches.clone();
        tokio::spawn(async move {
            while let Some((command, reply)) = rx.recv().await {
                if matches!(command, DesktopCommand::Insert(_)) {
                    observed.fetch_add(1, Ordering::SeqCst);
                }
                let _ = reply.send(Ok(()));
            }
        });
        let app = App {
            db: Arc::new(Mutex::new(db)),
            invitation: Arc::new(Mutex::new(Invitation {
                code: String::new(),
                until: Instant::now(),
                attempts: 0,
            })),
            lease: Arc::new(Mutex::new(Some(Lease {
                owner: "phone".into(),
                heartbeat: Instant::now(),
            }))),
            desktop: tx,
            speech: SpeechService::new(
                std::env::temp_dir().join(format!("nexus-remote-test-{}", uuid::Uuid::new_v4())),
            )
            .unwrap(),
            x11_session: true,
        };
        let operation = uuid::Uuid::new_v4().to_string();
        let params = json!({"operation_id":operation,"text":"Welkom 🦊\nnext line"});
        let first = process(&app, "phone", "text.insert", params.clone())
            .await
            .unwrap();
        let second = process(&app, "phone", "text.insert", params).await.unwrap();
        assert_eq!(first, json!({"status":"paste_dispatched"}));
        assert_eq!(second, first);
        assert_eq!(dispatches.load(Ordering::SeqCst), 1);
        let unknown = uuid::Uuid::new_v4().to_string();
        app.db
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO receipts (id,state) VALUES (?1,'unknown')",
                [&unknown],
            )
            .unwrap();
        let result = process(
            &app,
            "phone",
            "text.insert",
            json!({"operation_id":unknown,"text":"same request"}),
        )
        .await
        .unwrap();
        assert_eq!(result, json!({"status":"unknown"}));
        assert_eq!(dispatches.load(Ordering::SeqCst), 1);
    }
}
