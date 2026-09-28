use serde_json::{Value, json};
use std::process::Stdio;
use tokio::process::Command;

fn valid_player(id: &str) -> bool {
    !id.is_empty()
        && id.len() < 200
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}
async fn command(program: &str, args: &[&str]) -> Result<String, &'static str> {
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .await
        .map_err(|_| "media_backend_unavailable")?;
    if !output.status.success() {
        return Err("media_command_failed");
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}
pub fn available() -> bool {
    std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_some() && std::env::var_os("PATH").is_some()
}
pub async fn players() -> ResultJson {
    let list = command("playerctl", &["-l"]).await.unwrap_or_default();
    let mut players = Vec::new();
    for id in list.lines().filter(|x| valid_player(x)).take(32) {
        let status = command("playerctl", &["-p", id, "status"])
            .await
            .unwrap_or_else(|_| "Stopped".into());
        let title = command(
            "playerctl",
            &["-p", id, "metadata", "--format", "{{title}}"],
        )
        .await
        .unwrap_or_default();
        let position = command("playerctl", &["-p", id, "position"])
            .await
            .ok()
            .and_then(|x| x.parse::<f64>().ok());
        let duration = command("playerctl", &["-p", id, "metadata", "mpris:length"])
            .await
            .ok()
            .and_then(|x| x.parse::<f64>().ok())
            .map(|micros| micros / 1_000_000.0);
        players.push(
            json!({"id":id,"title":title,"status":status,"position_seconds":position,
            "duration_seconds":duration,"can_seek":duration.is_some_and(|x|x>0.0)}),
        );
    }
    Ok(json!({"players":players}))
}
pub async fn action(id: &str, action: &str) -> ResultJson {
    if !valid_player(id) {
        return Err("invalid_player");
    }
    let arguments: Vec<&str> = match action {
        "play_pause" => vec!["-p", id, "play-pause"],
        "next" => vec!["-p", id, "next"],
        "previous" => vec!["-p", id, "previous"],
        "forward" => vec!["-p", id, "position", "10+"],
        "backward" => vec!["-p", id, "position", "10-"],
        _ => return Err("invalid_media_action"),
    };
    command("playerctl", &arguments).await?;
    Ok(json!({}))
}
pub async fn seek(id: &str, seconds: i32) -> ResultJson {
    if !valid_player(id) || !(0..=86400).contains(&seconds) {
        return Err("invalid_seek");
    }
    let position = seconds.to_string();
    command("playerctl", &["-p", id, "position", &position]).await?;
    Ok(json!({}))
}
pub async fn volume_state() -> ResultJson {
    let volume = command("pactl", &["get-sink-volume", "@DEFAULT_SINK@"]).await?;
    let percent = volume
        .split_whitespace()
        .find_map(|word| {
            word.strip_suffix('%')
                .and_then(|digits| digits.parse::<u32>().ok())
        })
        .ok_or("volume_unavailable")?;
    let muted = command("pactl", &["get-sink-mute", "@DEFAULT_SINK@"])
        .await?
        .contains("yes");
    Ok(json!({"percent":percent.min(100),"muted":muted}))
}
pub async fn set_volume(percent: i32) -> ResultJson {
    if !(0..=100).contains(&percent) {
        return Err("invalid_volume");
    }
    let value = format!("{percent}%");
    command("pactl", &["set-sink-volume", "@DEFAULT_SINK@", &value]).await?;
    volume_state().await
}
pub async fn set_mute(muted: bool) -> ResultJson {
    command(
        "pactl",
        &[
            "set-sink-mute",
            "@DEFAULT_SINK@",
            if muted { "1" } else { "0" },
        ],
    )
    .await?;
    volume_state().await
}
type ResultJson = Result<Value, &'static str>;
