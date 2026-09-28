# Implementation status

The product specification defines five milestones. This repository currently provides a Linux/X11 development build. The complete first release is not yet validated.

## Implemented

- Flutter Android app with Remote, Write, and Media destinations.
- Manual TLS fingerprint pinning, single-use pairing code, per-phone hashed credentials, and controller lease timeout.
- X11 pointer, clicks, scroll, key chords, UTF-8 clipboard publication, and explicit paste dispatch.
- Draft persistence, separate Enter action, 16 kHz WAV recording, audio normalization, authenticated upload, and exactly-once transcript append for a job ID.
- Separate CPU whisper.cpp worker pinned to commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`; default multilingual large-v3-turbo Q5_0 model manifest and verified installer.
- Linux MPRIS player control through `playerctl` and default-output volume through `pactl`.
- Duplicate text insertion receipts and duplicate completed speech-job responses in host memory.

## Validation completed here

- `cargo test` and `flutter test` pass.
- `flutter analyze` passes.
- C++ worker builds and transcribes a sample with the pinned default model. Repeated jobs and digital silence were checked.
- Local HTTPS pairing, authenticated WAV upload, transcription, and duplicate-job return pass an end-to-end script.
- An Android debug APK builds for device installation.

## Required before the specified release

- Physical Android testing, recording interruption tests, gesture tests, accessibility tests, and Android release signing.
- Native Windows 11 input, clipboard, media, volume, installer, and validation.
- GNOME and KDE Wayland Remote Desktop and Clipboard portal implementations and separate validation.
- Desktop setup window, QR pairing, companion-side manual approval, device revocation, discovery, and VPN configuration UI.
- Speech model selection and automatic worker idle unload; the specified lightweight Small Q5_0 model is not in the pinned upstream model catalog and needs a reproducible conversion and manifest.
- Async speech job status and cancellation APIs, durable pending-job reconciliation, and retained-audio management UI.
- Direct D-Bus and PulseAudio client implementations to replace the current `playerctl`/`pactl` development adapters.
- Full protocol schemas and cross-language fixtures, release installers, diagnostics bundle, compatibility matrix, and speech accuracy corpus.

On Wayland, the companion reports desktop input and clipboard as unsupported while keeping speech available. It does not claim full Wayland compatibility.

The current APK is debug signed. Do not distribute it as a production release.
