# Nexus Remote

Android remote for a desktop computer. This repository implements a Linux/X11 development build of the [product specification](docs/specification.md).

## Layout

- `mobile/`: Flutter Android application.
- `companion/`: Rust desktop service and setup command.
- `protocol/`: version 1 wire contract and fixtures.
- `speech-worker/`: local C++ whisper.cpp worker.
- `models/`: pinned model manifest and checksum-verifying installer.

## Development

The companion currently supports desktop input on a logged-in X11 session. Build the Rust companion and C++ worker, then install the default model:

```sh
cargo build --release --manifest-path companion/Cargo.toml
cmake -S speech-worker -B speech-worker/build -DCMAKE_BUILD_TYPE=Release
cmake --build speech-worker/build --target nexus-remote-speech-worker -j 8
python3 models/install.py quality
```

Set `NEXUS_REMOTE_MODEL` to the printed model path and `NEXUS_REMOTE_WORKER` to the built worker executable, then start the companion from the desktop session. It prints a pairing code valid for two minutes and the full TLS fingerprint. Enter its address, fingerprint, and code in the mobile app. The phone must reach TCP port 45679.

For a packaged desktop build, run `sh packaging/linux/build-portable.sh` and start the resulting `nexus-remote-linux-x11-dev/run.sh`. That launcher installs and verifies the pinned quality model automatically on first run, or reuses a verified installation. The model is downloaded separately because the 574 MB binary is not kept in Git. If you already have the model file, install it without a download using `python3 models/install.py quality --source /path/to/ggml-large-v3-turbo-q5_0.bin`.

Run `flutter run` from `mobile/` on an Android device, or install the development APK in `dist/`. No cloud speech service is involved. The optional `test-tiny` model is only for development checks; use the quality model for product evaluation.

This shared workspace is mounted without execute permission. Build outputs must live on an executable filesystem such as `/tmp`; `packaging/linux/build-portable.sh` uses `/tmp` by default. The attached development bundle was built and tested that way.

See [status](docs/status.md) for implemented features, setup dependencies, and outstanding release work. The current APK is debug signed and the companion setup UI, revocation, Windows and Wayland input, and release validation remain unfinished.
