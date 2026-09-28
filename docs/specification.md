# Nexus Remote — detailed product and implementation specification

## 1. Product definition

Nexus Remote turns an Android phone into a controller for the computer in front of you. Its central feature is speaking a prompt into the phone, reviewing the transcription, and inserting it into the computer application you are using.

The first release combines four capabilities:

1. A responsive touchpad and keyboard remote.
2. Local speech transcription for short and several-minute prompts.
3. A prompt editor with reusable snippets and configurable shortcuts.
4. Media playback and system-volume controls.

The product should work independently of NexusLink. NexusLink remains a reference for useful interaction patterns and existing platform knowledge.

### Confirmed decisions

| Area | Decision |
|---|---|
| Mobile framework | Flutter |
| Primary mobile platform | Android |
| Computer platforms | Windows and Linux |
| Linux desktops | X11 plus GNOME/KDE Wayland |
| Main voice function | Dictation into PC applications |
| Voice delivery | Review on phone, then explicitly insert |
| Submission | Separate Enter action |
| Speech processing | Local model on the computer |
| Languages | English and Dutch, including both within one prompt |
| Video-related controls | Media remote |
| Connectivity | Local Wi-Fi and an existing private VPN |
| Agent integration | Universal input controls |
| PC installation | Independent Nexus Remote companion |

### Primary scenario

The user has an agent, editor, browser, or terminal open on the computer.

They use the phone to position the cursor, focus a text field, and record:

> “Change the heading to ‘Welkom bij onze winkel’ and put ‘Gratis verzending vanaf vijftig euro’ below the button.”

The transcript appears on the phone. The user corrects any recognition errors, taps **Insert into PC**, checks the computer screen, and taps **Enter** when ready.

### First-release boundaries

Include the complete workflow above. Defer:

- Streaming the computer screen to the phone.
- Exposing the phone as a virtual PC microphone.
- Reading agent conversations or managing agent permissions.
- Automatic prompt rewriting, translation, or summarization.
- Hosted accounts, public internet relays, and automatic router configuration.
- iOS, macOS hosts, and ARM desktop builds.
- Always-listening activation and recording while the phone is locked.
- Arbitrary remote shell-command execution.

These boundaries keep the first release focused without preventing later extensions.

---

## 2. Current environment and reuse strategy

The Nexus Remote project directory is empty. The inspected NexusLink project already contains Flutter gestures, pairing, desktop input, clipboard access, and Android speech recognition.

The inspected development machine has:

- Flutter 3.44.8 and Dart 3.12.2.
- Android SDK platforms through API 36.
- Zorin OS 18.1 using GNOME/X11.
- An AMD Ryzen 7 7800X3D and approximately 30 GiB RAM.
- CMake available.
- No Rust toolchain found on the current executable search path.

### Reuse decisions

- Reuse interaction knowledge and suitable isolated gesture logic.
- Preserve attribution for any source copied from NexusLink.
- Define a new protocol and pairing implementation.
- Keep NexusLink’s repository and its existing uncommitted changes untouched.
- Avoid importing its agent, terminal, file-browser, screen-streaming, or virtual-display systems.
- Avoid inheriting its Linux text truncation and Windows character-by-character text injection.

### Project organization

The new repository will contain these logical areas:

| Area | Responsibility |
|---|---|
| Mobile application | Flutter screens, gestures, recording, drafts, networking |
| Companion application | Rust desktop UI, connection server, platform integration |
| Speech worker | Small C++ process wrapping whisper.cpp |
| Protocol definitions | JSON Schema, examples, compatibility rules, test fixtures |
| Packaging | Android, Windows, and Linux release scripts |
| Documentation | Setup, architecture, troubleshooting, compatibility, test results |

The mobile and companion applications have independent build commands but share a single release version and protocol contract.

---

## 3. Interface and interaction design

### Navigation

Use three main destinations:

- **Remote**
- **Write**
- **Media**

A persistent top bar shows the selected computer, connection state, and access to settings. A computer picker supports switching between saved hosts.

The microphone remains available from Remote and Write. The app remembers the last destination for each computer.

### Visual language

Use a restrained dark interface with clear control boundaries:

| Token | Initial value |
|---|---|
| Background | `#0E1116` |
| Surface | `#161C24` |
| Raised surface | `#202A36` |
| Border | `#2D3948` |
| Primary accent | `#8AE3CB` |
| Primary text | `#F4F7FC` |
| Secondary text | `#A7B3C2` |
| Warning | `#F4C76B` |
| Error | `#FF8080` |

Use the platform’s standard sans-serif typography. Avoid decorative gradients, animated backgrounds, and unnecessary visual effects.

Specific layout rules:

- Minimum interactive target: 48 logical pixels.
- Main microphone control: approximately 72 logical pixels.
- Standard page padding: 16 logical pixels.
- Spacing based on 4, 8, 12, 16, and 24 logical pixels.
- Connection and recording states always include text, not color alone.
- Support system text scaling up to 200% without losing essential actions.
- Respect system reduced-motion preferences.
- Use short haptic feedback for recording start/stop and discrete clicks.
- Keep animations brief, generally 120–180 ms.

Portrait is the primary layout. At widths of at least 600 logical pixels, use a two-column layout where appropriate, such as the touchpad beside shortcut controls.

### Remote screen

Arrange the screen vertically:

1. Computer and connection status.
2. Large touchpad occupying most available space.
3. Dedicated left- and right-click controls.
4. Compact shortcut row.
5. Microphone dock and a preview of the current draft.

The initial shortcut row contains Escape, Tab, Enter, Copy, and Paste. Additional controls open a keyboard panel with arrows and modifier keys.

The touchpad does not show a miniature desktop or a simulated cursor. Its job is relative pointer movement while the user watches the PC.

### Write screen

The Write screen contains:

- A multiline text editor.
- Recording controls.
- Transcription and upload status.
- A snippets drawer.
- **Insert into PC**.
- **Copy on phone**.
- A separate Enter control.

The editor supports ordinary Android text input. Gboard voice typing can therefore populate the editor without a special integration.

Recording results append to the current draft, separated by a newline when the draft already contains text. They do not overwrite manual corrections.

An insertion does not automatically clear the text. The user can inspect, edit, or reuse it. Retain a single active draft per saved computer rather than creating an automatic transcript history.

### Media screen

Show:

- Available media players.
- Selected player and track/video title when provided by the PC.
- Play/pause.
- Previous/next.
- Backward/forward seek by 10 seconds.
- A seek bar when the player exposes a valid timeline.
- System-volume slider and mute.

Keep system volume visually separate from playback position. Do not present system volume as a per-app volume control.

If the selected player disappears, show that state and refresh the player list. Do not silently send its pending commands to another player.

### Settings

Group settings into:

- Computers and pairing.
- Speech model and language.
- Touchpad sensitivity and scroll direction.
- Keyboard and paste shortcuts.
- Saved snippets and shortcut buttons.
- Appearance, haptics, and screen-awake behavior.
- Storage and diagnostics.

Use product language in these screens. Keep protocol versions, transport details, and raw platform errors inside diagnostics.

---

## 4. Touchpad and keyboard behavior

### Gesture specification

| Gesture | Behavior |
|---|---|
| One-finger movement | Relative pointer movement |
| One-finger tap | Left click |
| Two quick one-finger taps | Two left clicks, interpreted by the PC as a double-click |
| Two-finger tap | Right click |
| Two-finger movement | Vertical or horizontal scrolling |
| Long press, then movement | Left-button drag |
| Finger release after dragging | Release left button |
| Dedicated left/right button | Explicit click |
| Hold dedicated left button while moving on the pad | Drag |

Use a dedicated recognizer for the touchpad area. Fingers interacting with the microphone or other controls must not become touchpad gesture participants.

Initial gesture constants:

- Tap movement tolerance: 8 logical pixels.
- Maximum tap duration: 250 ms.
- Double-tap interval: 300 ms.
- Long press to begin drag: 450 ms.
- No momentum scrolling in the first release.
- No pinch gesture in the first release.

A long press becomes a drag operation, not a right click. This avoids having the same gesture trigger two different actions.

### Pointer processing

- Use logical movement deltas, independent of phone resolution and PC monitor size.
- Default sensitivity multiplier: 1.0; configurable from 0.25 to 3.0.
- Provide a precision toggle that applies a further 0.35 multiplier.
- Avoid adding custom acceleration initially; let the desktop apply its normal pointer behavior.
- Accumulate fractional movement rather than discarding subpixel deltas.
- Send coalesced movement at up to 60 updates per second.
- Flush pending movement before button transitions so clicks occur at the intended position.
- Bound queues and discard stale movement instead of allowing pointer lag to accumulate.

### Keyboard behavior

Text entry and key commands are separate features:

- Text is composed on the phone and inserted in a batch.
- Enter, Escape, arrows, and shortcuts are discrete key commands.
- Android IME composition is never forwarded character by character.
- Modifier buttons latch for the next shortcut and then reset.
- Host-generated chords always release modifiers, including after errors.
- Copy means the PC’s copy shortcut.
- Paste means the PC’s current clipboard paste shortcut.
- Neither action implies automatic clipboard synchronization with the phone.

Custom shortcut buttons support a label and a key chord. They do not execute shell commands or scripts.

---

## 5. Recording and transcription experience

### Recording modes

Provide an explicit mode selector:

- **Hold:** press and hold to record; release to stop.
- **Tap:** tap once to start; tap again to stop.

Remember the chosen mode. Do not infer the mode from how quickly the user taps, because ambiguous start/stop behavior is unacceptable for the main feature.

While recording:

- Show a timer and audio-level indicator.
- Give clear start/stop haptics.
- Keep the screen awake.
- Provide a Cancel action.
- In Hold mode, sliding approximately 80 logical pixels away from the button cancels.
- Stop automatically at five minutes and process the captured recording.

Accessibility users must be able to use Tap mode through ordinary labeled buttons.

### Android audio capture

Use the Flutter `record` package behind an application-owned recording interface. It provides Android recording and PCM/WAV support. [Package documentation](https://pub.dev/packages/record)

Implementation choices:

- Minimum Android API: 26.
- Compile and target API: 36 for the initial development baseline.
- Capture mono, 16-bit PCM at 16 kHz.
- Save a valid WAV file in application-private storage.
- Verify the actual captured format; resample in the recording adapter if the device cannot provide the requested rate.
- Use the phone’s built-in microphone as the first-release supported route.
- Request microphone access when the user first records.
- Request camera access only when scanning a pairing QR code.
- Keep touchpad, keyboard, and media controls usable when microphone permission is denied.

Recording is foreground-only. On app backgrounding, screen locking, microphone interruption, or an incoming call, stop the recording and preserve usable captured audio.

Do not implement a microphone foreground service in this release.

### Speech workflow

The complete pipeline is:

1. Record locally on the phone.
2. Finalize and validate the WAV file.
3. Upload it over the authenticated HTTPS connection.
4. Validate the upload on the companion.
5. Run transcription in the speech worker.
6. Return the result and timing information.
7. Persist the result in the phone’s draft.
8. Append the result exactly once.
9. Allow editing and explicit insertion.

The first release does not claim live transcription while the user is speaking. The live display shows recording activity; transcription begins after recording stops.

### Speech models

Use whisper.cpp with:

- **Quality:** multilingual `large-v3-turbo`, Q5_0 quantization; default.
- **Lightweight:** multilingual `small`, Q5_0 quantization.

Use multilingual models, not `.en` variants. whisper.cpp supports these model families, quantization, CPU execution, Windows, and Linux. [Project documentation](https://github.com/ggml-org/whisper.cpp)

Model selection is explicit. Do not silently switch models or upload audio to a cloud service after an error.

CPU operation is mandatory for the first release. GPU acceleration is an extension point, not a dependency for completing the initial product.

### English/Dutch behavior

Default language setting: **Automatic — English and Dutch use case**.

Also expose English and Dutch overrides for recordings dominated by one language.

Configure transcription with:

- Translation disabled.
- No summarization or rewriting.
- No automatic replacement of Dutch with English.
- No inheritance of earlier recordings as hidden text context.
- Original punctuation and wording preserved except for the transcription model’s own output.

Automatic language detection does not guarantee perfect recognition of language switches. The review step remains essential.

Do not apply a second language model to “improve” the transcript. That could change the meaning of Dutch site copy or technical instructions.

### Silence and difficult audio

Use voice activity detection to identify speech and avoid passing entirely silent recordings through normal transcription.

- Silence must yield “No speech detected,” not an invented transcript.
- Quiet speech must remain testable; do not rely solely on a fixed volume threshold.
- Background noise can reduce recognition quality; retain the original recording for retry.
- Do not expose uncalibrated confidence percentages to the user.
- Do not automatically insert any recognized text.

---

## 6. Speech-worker implementation

Use a separate C++ executable that links to a pinned whisper.cpp revision.

This worker contains only audio preparation, model loading, inference, and result serialization. It has no network listener and no desktop-input privileges.

### Why a separate process

This design provides:

- A model that stays loaded between recordings.
- Isolation from native inference crashes.
- Independent cancellation and recovery.
- A responsive companion and touchpad during heavy inference.
- A replaceable speech engine boundary.

### Process communication

The Rust companion launches the worker and communicates through private standard-input/output pipes.

Use length-prefixed JSON messages for:

- Initialize with model identifier.
- Load or unload model.
- Transcribe a host-created temporary audio file.
- Report progress.
- Return final text and segment timestamps.
- Cancel a job.
- Report a structured failure.
- Shut down.

The worker receives only paths created by the companion. The network API never accepts arbitrary filesystem paths.

Reserve stdout for the framed protocol. Send sanitized diagnostic messages to stderr.

### Execution policy

- One active transcription job per companion.
- Additional requests receive a `busy` response rather than building an unbounded queue.
- Keep the selected model loaded while a phone is connected.
- Unload it after ten minutes without connected phones or jobs.
- Use up to eight inference threads, capped at half the machine’s logical CPU count, with a minimum of one.
- Let whisper.cpp perform its normal transcription segmentation; do not invent a separate transcript-merging algorithm.
- Use its progress and abort facilities through the wrapper. [whisper.cpp API](https://github.com/ggml-org/whisper.cpp/blob/master/include/whisper.h)

For cancellation, request cooperative abort. If the worker fails to stop within two seconds, terminate it and restart before the next job.

If the worker crashes, preserve the recording on the phone and expose Retry. Do not repeatedly restart and reprocess audio without a user-visible result.

### Model installation

Maintain a release-pinned manifest containing:

- Model ID and display name.
- Engine compatibility version.
- Download location.
- Expected byte length.
- SHA-256 checksum.
- License/attribution information.

Download to a temporary file, verify it, then atomically rename it into the model cache. Interrupted downloads may resume only when server validators match.

Never execute downloaded model content. Do not load an incomplete or checksum-mismatched model.

---

## 7. Application architecture and code responsibilities

### Flutter architecture

Use Riverpod for dependency injection and application state. Use immutable state objects and keep widgets free of transport and platform logic.

| Component | Code responsibility |
|---|---|
| `ConnectionController` | Pairing, reconnects, host selection, capabilities, connection status |
| `RemoteController` | Input lease, gesture commands, modifier state, release-all behavior |
| `RecordingController` | Permissions, audio lifecycle, interruption handling, file finalization |
| `TranscriptionController` | Uploads, job status, cancellation, retries, result reconciliation |
| `DraftController` | Editing, autosave, recording append, insertion attempts |
| `MediaController` | Player selection, state subscription, playback and volume commands |
| `SettingsRepository` | Non-secret preferences and per-host settings |
| `CredentialStore` | Device tokens and trusted host fingerprints |
| `DraftRepository` | Draft text, recording references, applied-result IDs |
| `RpcClient` | Typed request/response transport and event subscriptions |

Use `flutter_secure_storage` for credentials, an application-private SQLite database for drafts and preferences, and files for recordings. [Secure-storage package](https://pub.dev/packages/flutter_secure_storage)

Use explicit serialization models for network messages. Avoid passing untyped maps through screen code.

### Rust companion architecture

Use:

- Tokio for asynchronous tasks.
- Axum for HTTP and WebSocket routing.
- rustls for TLS.
- serde for protocol serialization.
- SQLite for durable host metadata.
- `mdns-sd` for discovery.
- egui/eframe for the desktop setup window.
- `windows` for Windows APIs.
- `ashpd`/`zbus` for Linux portals and D-Bus.
- `x11rb` for X11 input and selection handling.

eframe supports native desktop applications and both Linux windowing systems, making it suitable for the small setup window. [eframe documentation](https://docs.rs/eframe/latest/eframe/)

Pin compatible dependency versions and commit lockfiles. Pin the Rust toolchain during implementation; do not depend on a floating nightly toolchain.

### Companion service boundaries

| Service | Responsibility |
|---|---|
| Pairing service | Expiring invitations, device credentials, revocation |
| Session manager | Authenticated connections and active controller ownership |
| Input dispatcher | Validated commands, ordering, held-input tracking |
| Text delivery service | Clipboard publication, paste dispatch, receipt tracking |
| Transcription service | Upload validation, job lifecycle, worker supervision |
| Model manager | Download, verification, model selection |
| Media service | Player enumeration, state updates, playback commands |
| Settings service | Local configuration and migrations |
| Diagnostics service | Sanitized logs and support bundle creation |

Platform implementations satisfy common interfaces such as:

- `InputBackend`
- `ClipboardBackend`
- `MediaBackend`
- `SystemVolumeBackend`
- `DesktopPermissionBackend`

Each interface reports capabilities and structured errors. Unsupported features must not return success.

### Concurrency

- The native UI stays on its required main thread.
- Network tasks use Tokio.
- Desktop input is serialized through a dedicated dispatcher.
- Platform APIs with thread-affinity requirements use dedicated threads.
- Speech inference stays in its separate process.
- Large uploads and model downloads never share the pointer event queue.

---

## 8. Connections, pairing, and protocol

### Network topology

Use direct phone-to-companion communication:

**Android app ⇄ HTTPS/WSS companion ⇄ desktop APIs and local speech worker**

No account server is required.

Default port: **45679**, separate from NexusLink’s existing default. Make it configurable in companion settings.

Use:

- WebSocket for commands, replies, and state events.
- HTTPS upload endpoints for audio.
- mDNS service type `_nexusremote._tcp.local` for LAN discovery.
- Saved host addresses for VPN connections.

mDNS is a convenience for local discovery. Do not assume it works across VPN networks.

### Host identity and TLS

Generate a persistent host identity and self-signed TLS certificate during setup.

The phone pins the certificate’s SHA-256 fingerprint. A host identity change requires pairing again; the app must not quietly trust a replacement certificate.

Avoid a global “accept all certificates” HTTP client. Any temporary certificate inspection during manual pairing must use an isolated path that cannot send credentials or control commands.

### QR pairing

The companion opens a pairing invitation valid for two minutes.

The QR contains:

- Protocol version.
- Host ID and display name.
- Candidate connection addresses.
- TLS certificate fingerprint.
- A cryptographically random, single-use pairing secret.

The phone scans it, establishes the pinned connection, and exchanges the invitation for a device credential.

The companion then shows the paired device and supports revoking it.

### Manual pairing

For manual setup:

1. Enter the address on the phone.
2. Compare the full certificate fingerprint shown on the phone with the companion.
3. Confirm the match.
4. Enter the temporary pairing code displayed by the companion.
5. Approve the device in the companion.

Limit attempts and expire the code after two minutes. Disable pairing endpoints when there is no active invitation.

An existing paired phone can later add a VPN address for the same pinned host without pairing again.

### Authentication and storage

Issue a random 256-bit credential per paired phone.

- Phone: store it in secure storage.
- Host: store a cryptographic hash of the credential.
- Send credentials in authorization headers, never URLs.
- Revocation invalidates existing sessions and closes their sockets.
- Discovery records contain no credentials.
- Do not copy NexusLink’s LAN authentication exceptions.

### Protocol format

Use protocol major version 1 with JSON Schema as the source of truth.

Request envelopes contain:

- Protocol major version.
- Request ID.
- Method.
- Typed parameters.

Responses contain the matching request ID and either a result or a structured error.

Events contain a topic, sequence number, and typed payload.

Unknown optional fields may be ignored. Unknown methods and unsupported major versions produce explicit errors.

### Public API groups

| Group | Operations |
|---|---|
| Host | Information, capabilities, model status |
| Controller | Acquire, release, heartbeat |
| Input | Relative move, scroll, button state, key chord, release all |
| Text | Insert, copy to PC clipboard, delivery-status lookup |
| Transcription | Create, upload, status, cancel, delete |
| Media | List/select players, playback command, seek, subscribe |
| Volume | Read state, set level, set mute |
| Devices | List/revoke through the local companion UI |

Audio uploads use separate authenticated HTTP endpoints. The host validates ownership for every job.

### Shared types

Define at least:

- `HostInfo`
- `HostCapabilities`
- `ConnectionState`
- `InputCommand`
- `TextInsertRequest`
- `TextDeliveryReceipt`
- `TranscriptionJob`
- `TranscriptResult`
- `MediaPlayer`
- `MediaState`
- `AppError`

Capabilities distinguish **supported**, **permission required**, **temporarily unavailable**, and **unsupported**. A single Boolean is insufficient for useful troubleshooting.

### Limits

Initial enforced limits:

| Resource | Limit |
|---|---|
| Recording duration | 300 seconds |
| Audio upload | 10 MiB for normalized PCM WAV |
| Text insertion | 64 KiB UTF-8 |
| WebSocket message | 512 KiB |
| Concurrent transcription | One |
| Active controlling phone | One |
| Saved paired phones | Multiple |

Reject oversized or invalid content with clear errors. Never silently truncate text or audio.

### Reconnection and controller ownership

- Reconnect after approximately 1, 2, 4, 8, then 15 seconds, with jitter.
- Stop automatic reconnect after credential revocation or certificate mismatch.
- Acquire a controller lease before sending desktop input.
- While controlling, send a heartbeat every second.
- Release held input after three seconds without the lease heartbeat.
- A second phone sees “Computer is being controlled by another device.”
- Switching computers releases the old lease before acquiring the new one.

After reconnection, fetch current state rather than assuming previous subscriptions or permissions survived.

Never replay old mouse movements, clicks, or key commands.

---

## 9. Platform implementations and text delivery

### Windows

Target Windows 11 x64 for the release test matrix.

Use:

- `SendInput` for pointer, button, and key commands.
- Native Unicode clipboard APIs for text publication.
- Windows media-session APIs for playback.
- Core Audio endpoint volume for system volume.

Run as a normal desktop-user application.

Windows restricts input injection across privilege boundaries. Elevated applications, UAC prompts, and the secure desktop are outside the supported control surface. Do not work around this by running the whole companion as administrator. [SendInput documentation](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)

### Linux/X11

Use the actual logged-in desktop session.

- XTest for pointer and keyboard events.
- X11 selection ownership for clipboard text.
- Support UTF-8 selection data and large transfers.
- Keep the clipboard provider alive long enough to serve paste requests.
- Use MPRIS for media.
- Use the PulseAudio client API, including PipeWire’s PulseAudio compatibility service, for default-output volume.

Do not spawn a shell command for every pointer event.

### Linux/Wayland

Use the Remote Desktop portal through `ashpd`/D-Bus.

Session setup:

1. Detect the portal and its available device types.
2. Create a session.
3. Select pointer and keyboard access.
4. Request clipboard access before starting the session.
5. Present the desktop permission prompt.
6. Store granted capabilities and any restore token.
7. Monitor session closure and permission revocation.

Use the portal’s D-Bus input methods in the first implementation. Do not establish an EIS connection and simultaneously use `Notify*` methods; the portal explicitly treats these as alternative input paths. [Remote Desktop portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html)

Implement clipboard publication through the Clipboard portal’s MIME ownership and transfer flow. [Clipboard portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Clipboard.html)

GNOME and KDE are separate release-test targets. Full Wayland support requires working pointer, keyboard, and clipboard capabilities on the tested desktop versions.

On an older or incomplete portal:

- Continue offering available features.
- Disable unavailable actions with a specific explanation.
- Preserve the phone draft.
- Offer Copy on phone as a recovery action.
- Do not install a root-level input daemon or claim full compatibility.

### Text insertion

The phone sends the exact edited text with an insertion operation ID and paste profile.

The companion:

1. Validates the request and active controller lease.
2. Records the operation as started.
3. Publishes the text to the PC clipboard.
4. Dispatches the configured paste chord.
5. Records and returns the dispatch result.

Defaults:

- Application profile: Ctrl+V.
- Linux terminal profile: Ctrl+Shift+V.
- Windows terminal profile: Ctrl+V.
- Allow a user-configured paste chord per host.

Preserve Unicode, line breaks, indentation, and leading/trailing spaces. Reject NUL characters; do not otherwise “clean up” content.

Insertion replaces the PC clipboard. Explain this once in the insertion setup. Do not automatically restore the previous clipboard after a timer because applications can read pasted data asynchronously.

### Focus and submission semantics

Text goes to the focused application when paste is dispatched.

The app must not imply that it has reliably identified the focused text field, especially on Wayland.

Nexus Remote never appends an Enter key to insertion. However, a target application can interpret pasted newlines according to its own behavior; “no Enter sent” is not a universal guarantee that multiline terminal text cannot execute.

### Delivery receipts

Distinguish:

- `rejected`
- `clipboard_ready`
- `paste_dispatched`
- `unknown`

`paste_dispatched` means the operating-system action was issued. It does not prove the destination field accepted the text.

Persist operation IDs without storing transcript content. A repeated request with the same ID returns its existing status instead of dispatching again.

If the companion crashes between dispatch and durable completion, report `unknown`. The phone keeps the draft and asks the user to inspect the computer before manually trying another insertion.

Do not promise exactly-once insertion into arbitrary applications.

---

## 10. Media-control implementation

### Linux

Use MPRIS over the session D-Bus connection.

Read:

- Player identity.
- Playback state.
- Track title.
- Position and duration when available.
- Supported actions.

Subscribe to state changes and respect capability flags such as whether seeking is supported. [MPRIS player specification](https://specifications.freedesktop.org/mpris/latest/Player_Interface.html)

### Windows

Use Global System Media Transport Controls sessions.

Enumerate available sessions, subscribe to playback changes, and use supported transport actions. Use Core Audio’s endpoint-volume interface for system volume and mute. [Core Audio documentation](https://learn.microsoft.com/en-us/windows/win32/api/endpointvolume/nn-endpointvolume-iaudioendpointvolume)

### Common behavior

- Select the currently playing session initially.
- Keep explicit user selection until the player disappears.
- Send absolute volume values rather than repeated “volume up” commands.
- Clamp system volume to 0–100%.
- Do not automatically raise volume when unmuting.
- Update local timeline display smoothly, then reconcile with host state.
- Disable unsupported seek and transport controls.
- When no player exists, retain system-volume controls and show an empty playback state.

Do not emulate seeking by blindly sending arrow keys to whichever window happens to be focused.

---

## 11. Persistence, state machines, and recovery

### Phone data

Store:

| Data | Location and lifecycle |
|---|---|
| Device credentials | Secure storage; removed when unpairing |
| Host fingerprints | Secure storage |
| Host addresses/settings | Application-private database |
| Current draft per host | Application-private database |
| Snippets and shortcut definitions | Application-private database |
| Recorded audio | Application-private files |
| Diagnostics | Bounded local logs |

Autosave editor changes after a 300 ms debounce and on lifecycle transitions.

A draft records its revision, source recording IDs, and already-applied transcription results. This prevents a repeated completion event from appending the same transcript twice.

Recording and job results remain attached to the original host and draft even if the user navigates elsewhere.

### Audio retention

- Keep phone audio until its draft is inserted or explicitly discarded.
- Delete host audio immediately after completion, failure cleanup, or cancellation.
- Keep completed transcript results in host memory for up to ten minutes for reconnection.
- Delete host temporary files left behind by a crash at startup.
- Cap pending phone audio at 100 MiB.
- When that cap is reached, ask the user to finish or discard existing recordings; do not delete unsent recordings silently.

### Recording states

`idle → requesting permission → recording → finalizing → ready`

Alternative outcomes include `cancelled`, `interrupted`, and `failed`.

### Transcription states

`ready → uploading → waiting for worker → transcribing → completed`

Alternative outcomes include `cancelled`, `failed`, and `connection lost`.

### Connection states

`disconnected → discovering/connecting → authenticating → connected`

Distinct blocked states include:

- Pairing required.
- Certificate changed.
- Permission required on PC.
- Protocol incompatible.
- Credential revoked.

### Failure behavior

| Failure | Required outcome |
|---|---|
| Connection lost while recording | Finish local recording; offer upload after reconnect |
| Upload interrupted | Keep audio; retry whole upload using job ID and checksum |
| Completion event missed | Query job status after reconnect |
| Companion restarted during transcription | Mark old job unavailable; allow explicit re-upload |
| Speech worker crashed | Preserve audio and show Retry |
| Model missing | Explain setup requirement; keep draft and other controls usable |
| Model download interrupted | Retain verified partial download metadata |
| Microphone denied | Keep keyboard, touchpad, and media available |
| Portal permission revoked | Release input, update capabilities, request local reauthorization |
| Paste acknowledgement lost | Query receipt; never automatically paste again |
| PC suspended | Show disconnected state and release local held controls |
| Android process killed | Recover saved draft and finalized recording on next launch |

Use structured error codes with user-facing messages and optional technical details. Do not display stack traces in normal screens.

---

## 12. Companion setup, installation, and operation

### Desktop setup window

Provide these sections:

- **Status:** running state, connected phone, permission status.
- **Pair phone:** QR code and manual pairing.
- **Speech:** selected model, installation progress, storage usage.
- **Devices:** paired phones and revoke action.
- **Settings:** port, addresses, autostart.
- **Diagnostics:** platform capabilities and export.

The companion runs as a single instance per OS user.

Closing its window leaves it running. Launching it again reopens the existing window through local IPC. Provide an explicit **Quit companion** action that releases input and shuts down the worker.

Autostart is opt-in and starts at user login, not as a privileged system service.

### Android delivery

- Build an installable APK for physical-phone testing.
- Include ARM64 support and an x86_64 development/emulator build.
- Keep release signing keys outside the repository.
- Do not require Google Play publication to test or complete the initial release.

### Windows delivery

Produce:

- A portable archive.
- A per-user installer.
- Companion executable, speech-worker executable, and required runtime files.
- Uninstall support that distinguishes application files from optional model-data removal.

The installer may offer a narrowly scoped firewall rule. It must not disable the firewall.

### Linux delivery

Produce:

- A `.deb` package for the Zorin/Ubuntu development target.
- A portable archive with an explicit dependency list for other distributions.

Bundle the application and speech worker. Declare required desktop libraries; do not assume every Linux installation has compatible portals, audio services, or graphical-session support.

### Build reproducibility

- Lock Dart and Rust dependencies.
- Pin whisper.cpp and model manifests.
- Build Windows artifacts on Windows.
- Build Linux artifacts on the documented baseline.
- Store checksums and third-party notices with releases.
- Separate model downloads from executable installation.

No automatic application updater in the first release. Manual upgrades preserve pairing and settings unless the host identity is deliberately reset.

---

## 13. Diagnostics, performance, and testing

### Diagnostics

Log:

- Application/protocol versions.
- Platform and capability results.
- Connection transitions.
- Job IDs and state changes.
- Upload, model-load, inference, and dispatch timings.
- Sanitized error codes.

Do not log:

- Audio.
- Transcript or clipboard content.
- Device credentials.
- Pairing secrets.
- Complete authorization headers.

Rotate logs with a total limit of 10 MiB. Support export with a preview of included categories.

No analytics service is required.

### Performance objectives

Treat these as engineering targets to measure, not claims already demonstrated:

| Area | Target |
|---|---|
| Phone touchpad rendering | Smooth 60 Hz interaction |
| Healthy LAN command acknowledgement | p95 below 100 ms |
| Held-input cleanup after lost lease | Within 3.5 seconds |
| Warm 10-second transcription on the development PC | Within 10 seconds using the default model |
| Transcription cancellation feedback | Immediate UI response |
| Worker cancellation/termination | Within 2 seconds |
| Recording duration | Five minutes without truncation |
| Idle companion | No continuous busy-loop rendering or polling |

Measure speech cold-start and warm inference separately. Publish results for both models.

If speech performance misses the target, optimize and document the measured limitation. Do not conceal it by silently changing the selected model.

### Automated tests

**Flutter**

- Gesture classification and cancellation.
- Modifier reset behavior.
- Recording-state transitions.
- Permission-denied behavior.
- Draft persistence and revision handling.
- Duplicate transcription events.
- Reconnection and receipt reconciliation.
- Layout and accessibility at large text scales.

**Rust**

- Authentication and invitation expiry.
- Device revocation.
- Protocol validation and size limits.
- Controller-lease expiry.
- Input release on disconnect.
- Text-operation deduplication and crash recovery.
- Audio validation.
- Worker crash/cancellation handling.
- Model checksum verification.
- Capability-dependent media actions.

**Cross-language contract tests**

Run identical protocol fixtures through Dart and Rust decoders. Include missing fields, unknown fields, unsupported versions, malformed inputs, and structured errors.

**Speech worker**

Test model initialization, silence detection, valid audio, cancellation, malformed files, progress events, and repeated jobs without process restart.

### Speech accuracy corpus

Create a reproducible test set containing:

- Ten English clips.
- Ten Dutch clips.
- Twenty mixed English/Dutch clips.
- Three recordings lasting two to five minutes.
- Additional silence and background-noise samples.

Mixed examples must include Dutch headings, prices, navigation labels, company names, and English technical instructions.

Measure:

- Word error rate after documented normalization.
- Dutch phrases accidentally translated into English.
- Missing or repeated phrases.
- Proper-name and technical-term errors.
- End-to-end processing time.

Initial quality targets:

- Clean English and Dutch: average word error rate no greater than 15%.
- Mixed clips: average word error rate no greater than 20%.
- At least 95% of marked Dutch spans remain Dutch rather than being translated.
- No fabricated transcript for the silence-only fixtures.

These are release gates to validate, not guarantees that every dictated quotation will be exact. The editable preview remains part of the product.

### Manual platform matrix

| Platform | Required validation |
|---|---|
| Physical Android phone | Recording, permissions, lifecycle, touchpad, pairing |
| Windows 11 x64 | Native input, clipboard, media, volume, installer |
| Zorin/GNOME X11 | Complete end-to-end workflow |
| GNOME Wayland | Portal permissions, clipboard, reconnect, revocation |
| KDE Wayland | Same tests independently |
| Private VPN connection | Manual address, certificate pinning, reconnect, latency |

Use a browser text area, a native editor, an agent composer, and a terminal with bracketed-paste behavior in the text-delivery tests.

Test:

- More than 512 characters.
- Up to the 64 KiB limit.
- Dutch diacritics, emoji, indentation, and multiline text.
- Paste without an additional Enter.
- Lost acknowledgements without duplicate insertion.
- Focus changes between recording and insertion.
- Multiple monitors.
- Multiple media players.
- Missing seek support.
- Desktop permission revocation.
- PC sleep/resume.

A feature is not considered tested merely because its mock backend passes.

---

## 14. Implementation sequence and completion criteria

### Milestone 1 — foundation and platform feasibility

Implement:

- Repository structure and pinned development toolchains.
- Protocol schemas and shared fixtures.
- Minimal Flutter shell and companion setup window.
- Platform probes.
- Direct pointer movement, clipboard publication, and paste on Windows, X11, GNOME Wayland, and KDE Wayland.

**Exit criterion:** each promised platform has a demonstrated native input-and-paste path. Wayland limitations are identified before building the full product around them.

### Milestone 2 — pairing and remote control

Implement:

- TLS identity and certificate pinning.
- QR/manual pairing.
- Device storage and revocation.
- Discovery and VPN address configuration.
- Controller leases.
- Touchpad, keyboard panel, and shortcut buttons.

**Exit criterion:** a paired Android phone controls the PC reliably and releases all held input after disconnection.

### Milestone 3 — complete voice workflow

Implement:

- Audio recording.
- Persistent drafts.
- Upload and transcription jobs.
- Speech-worker process.
- Model installation.
- English/Dutch settings.
- Review and insertion receipts.

**Exit criterion:** a several-minute mixed-language prompt can be recorded, transcribed, edited, and inserted without truncation or automatic resubmission.

### Milestone 4 — media and interaction polish

Implement:

- Player discovery and playback controls.
- System volume.
- Snippets and configurable shortcuts.
- Responsive layouts.
- Accessibility and haptics.
- User-facing error and recovery flows.

**Exit criterion:** the three main destinations feel coherent and all capability-dependent controls accurately reflect the host.

### Milestone 5 — release hardening

Complete:

- Physical-device and desktop test matrix.
- Speech accuracy and performance measurements.
- Installer testing.
- Upgrade and uninstall checks.
- Log-redaction checks.
- Compatibility documentation.
- APK and companion release artifacts.

**Exit criterion:** all functional and accuracy gates pass, known platform limitations are documented, and a new user can install, pair, download a model, and complete the primary workflow using the setup instructions.

The initial delivery includes the applications, reproducible build scripts, protocol documentation, automated tests, measured speech results, and a verified platform compatibility matrix. A prototype UI or a single-platform demonstration does not constitute completion.