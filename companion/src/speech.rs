use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    io::Read,
    path::PathBuf,
    process::Stdio,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::{Child, ChildStdin, ChildStdout, Command},
    sync::Mutex,
};
use uuid::Uuid;

#[derive(Clone)]
pub struct SpeechService(Arc<Inner>);
struct Inner {
    model: Option<PathBuf>,
    worker_path: PathBuf,
    audio_dir: PathBuf,
    busy: AtomicBool,
    worker: Mutex<Option<Worker>>,
    completed: Mutex<HashMap<(String, String), (Instant, Value)>>,
}
struct Worker {
    child: Child,
    stdin: ChildStdin,
    stdout: ChildStdout,
    loaded: bool,
}
struct Busy<'a>(&'a AtomicBool);
impl Drop for Busy<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

fn verified_model(path: &PathBuf) -> bool {
    let manifest: Value = match serde_json::from_str(include_str!("../../models/manifest.json")) {
        Ok(value) => value,
        Err(_) => return false,
    };
    let Some(filename) = path.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    let Some(entries) = manifest.get("models").and_then(Value::as_object) else {
        return false;
    };
    let Some(entry) = entries
        .values()
        .find(|entry| entry.get("filename").and_then(Value::as_str) == Some(filename))
    else {
        return false;
    };
    let expected_size = entry.get("bytes").and_then(Value::as_u64).unwrap_or(0);
    let expected_hash = entry.get("sha256").and_then(Value::as_str).unwrap_or("");
    if path.metadata().map(|metadata| metadata.len()).ok() != Some(expected_size) {
        return false;
    }
    let Ok(mut file) = std::fs::File::open(path) else {
        return false;
    };
    let mut digest = Sha256::new();
    let mut block = [0u8; 1024 * 1024];
    loop {
        match file.read(&mut block) {
            Ok(0) => break,
            Ok(count) => digest.update(&block[..count]),
            Err(_) => return false,
        }
    }
    hex::encode(digest.finalize()) == expected_hash
}

impl SpeechService {
    pub fn new(audio_dir: PathBuf) -> std::io::Result<Self> {
        std::fs::create_dir_all(&audio_dir)?;
        for file in std::fs::read_dir(&audio_dir)?.flatten() {
            if file.path().extension().is_some_and(|ext| ext == "wav") {
                let _ = std::fs::remove_file(file.path());
            }
        }
        let model = std::env::var_os("NEXUS_REMOTE_MODEL")
            .map(PathBuf::from)
            .filter(verified_model);
        let worker_path = std::env::var_os("NEXUS_REMOTE_WORKER")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                std::env::current_exe()
                    .unwrap_or_default()
                    .with_file_name("nexus-remote-speech-worker")
            });
        Ok(Self(Arc::new(Inner {
            model,
            worker_path,
            audio_dir,
            busy: AtomicBool::new(false),
            worker: Mutex::new(None),
            completed: Mutex::new(HashMap::new()),
        })))
    }
    pub fn available(&self) -> bool {
        self.0.model.as_ref().is_some_and(|p| p.is_file()) && self.0.worker_path.is_file()
    }
    pub async fn transcribe(
        &self,
        device: &str,
        job_id: &str,
        language: &str,
        audio: &[u8],
    ) -> Result<Value, &'static str> {
        Uuid::parse_str(job_id).map_err(|_| "invalid_job_id")?;
        if language != "auto" && language != "en" && language != "nl" {
            return Err("invalid_language");
        }
        let key = (device.to_string(), job_id.to_string());
        if let Some((_, result)) = self.0.completed.lock().await.get(&key) {
            return Ok(result.clone());
        }
        if !self.available() {
            return Err("model_missing");
        }
        if !valid_wav(audio) {
            return Err("invalid_audio");
        }
        if self
            .0
            .busy
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            return Err("busy");
        }
        let _busy = Busy(&self.0.busy);
        let path = self.0.audio_dir.join(format!("{}.wav", Uuid::new_v4()));
        tokio::fs::write(&path, audio)
            .await
            .map_err(|_| "audio_storage_error")?;
        let result = self.run_worker(job_id, language, &path).await;
        let _ = tokio::fs::remove_file(&path).await;
        if let Ok(value) = &result {
            let mut completed = self.0.completed.lock().await;
            completed.retain(|_, (at, _)| at.elapsed() < Duration::from_secs(600));
            completed.insert(key, (Instant::now(), value.clone()));
        }
        result
    }
    async fn run_worker(
        &self,
        id: &str,
        language: &str,
        path: &PathBuf,
    ) -> Result<Value, &'static str> {
        let mut slot = self.0.worker.lock().await;
        if slot.is_none() {
            let mut child = Command::new(&self.0.worker_path)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|_| "worker_unavailable")?;
            let stdin = child.stdin.take().ok_or("worker_unavailable")?;
            let stdout = child.stdout.take().ok_or("worker_unavailable")?;
            *slot = Some(Worker {
                child,
                stdin,
                stdout,
                loaded: false,
            });
        }
        let worker = slot.as_mut().ok_or("worker_unavailable")?;
        if !worker.loaded {
            let model = self.0.model.as_ref().ok_or("model_missing")?;
            let command = json!({"id":Uuid::new_v4().to_string(),"method":"load","path":model});
            let outcome =
                tokio::time::timeout(Duration::from_secs(120), worker.call(command)).await;
            match outcome {
                Ok(Ok(answer)) if answer.get("error").is_none() => worker.loaded = true,
                other => {
                    let code = match other {
                        Err(_) => "model_load_timeout",
                        Ok(Ok(_)) => "model_load_failed",
                        Ok(Err(_)) => "worker_unavailable",
                    };
                    let _ = worker.child.kill().await;
                    *slot = None;
                    return Err(code);
                }
            }
        }
        let command = json!({"id":id,"method":"transcribe","path":path,"language":language});
        let outcome = tokio::time::timeout(Duration::from_secs(360), worker.call(command)).await;
        match outcome {
            Ok(Ok(answer)) => {
                if answer.get("error").is_some() {
                    return Err("transcription_failed");
                }
                answer.get("result").cloned().ok_or("worker_protocol_error")
            }
            _ => {
                let _ = worker.child.kill().await;
                *slot = None;
                Err("worker_unavailable")
            }
        }
    }
}
impl Worker {
    async fn call(&mut self, request: Value) -> Result<Value, &'static str> {
        let message = request.to_string().into_bytes();
        let len = u32::try_from(message.len()).map_err(|_| "worker_protocol_error")?;
        self.stdin
            .write_all(&len.to_le_bytes())
            .await
            .map_err(|_| "worker_unavailable")?;
        self.stdin
            .write_all(&message)
            .await
            .map_err(|_| "worker_unavailable")?;
        self.stdin.flush().await.map_err(|_| "worker_unavailable")?;
        let mut header = [0u8; 4];
        self.stdout
            .read_exact(&mut header)
            .await
            .map_err(|_| "worker_unavailable")?;
        let size = u32::from_le_bytes(header) as usize;
        if size == 0 || size > 1024 * 1024 {
            return Err("worker_protocol_error");
        }
        let mut response = vec![0u8; size];
        self.stdout
            .read_exact(&mut response)
            .await
            .map_err(|_| "worker_unavailable")?;
        serde_json::from_slice(&response).map_err(|_| "worker_protocol_error")
    }
}

fn valid_wav(audio: &[u8]) -> bool {
    if audio.len() < 44
        || audio.len() > 10 * 1024 * 1024
        || &audio[..4] != b"RIFF"
        || &audio[8..12] != b"WAVE"
    {
        return false;
    }
    let mut format = false;
    let mut data = false;
    let mut offset = 12usize;
    while offset + 8 <= audio.len() {
        let size = u32::from_le_bytes(audio[offset + 4..offset + 8].try_into().unwrap()) as usize;
        let begin = offset + 8;
        if size > audio.len() - begin {
            return false;
        }
        if &audio[offset..offset + 4] == b"fmt " {
            if size < 16 {
                return false;
            }
            let chunk = &audio[begin..begin + 16];
            format = chunk[0..2] == [1, 0]
                && chunk[2..4] == [1, 0]
                && chunk[4..8] == 16000u32.to_le_bytes()
                && chunk[14..16] == [16, 0];
        }
        if &audio[offset..offset + 4] == b"data" {
            data = size > 0 && size % 2 == 0 && size <= 16000 * 2 * 300;
        }
        offset = begin + size + (size % 2);
    }
    format && data
}

#[cfg(test)]
mod tests {
    use super::valid_wav;
    #[test]
    fn validates_pcm_format_and_five_minute_limit() {
        let mut wav = vec![0; 44 + 32000];
        wav[0..4].copy_from_slice(b"RIFF");
        wav[8..12].copy_from_slice(b"WAVE");
        wav[12..16].copy_from_slice(b"fmt ");
        wav[16..20].copy_from_slice(&16u32.to_le_bytes());
        wav[20..22].copy_from_slice(&1u16.to_le_bytes());
        wav[22..24].copy_from_slice(&1u16.to_le_bytes());
        wav[24..28].copy_from_slice(&16000u32.to_le_bytes());
        wav[34..36].copy_from_slice(&16u16.to_le_bytes());
        wav[36..40].copy_from_slice(b"data");
        wav[40..44].copy_from_slice(&32000u32.to_le_bytes());
        assert!(valid_wav(&wav));
        wav[24..28].copy_from_slice(&44100u32.to_le_bytes());
        assert!(!valid_wav(&wav));
    }
}
