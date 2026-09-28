Nexus Remote Linux/X11 development bundle

Requirements: x86_64 Linux with an X11 desktop session, glibc and libstdc++,
playerctl, pactl, a PulseAudio-compatible audio service, and a session D-Bus.

Start from the logged-in X11 session:
    ./run.sh

On first run, the launcher downloads the pinned 574 MB speech model and verifies
its checksum. Later runs reuse the installed model. Python 3 is required for
the launcher; an internet connection is needed for the first download.
To install an existing verified copy without downloading it, run:
    python3 models/install.py quality --source /path/to/ggml-large-v3-turbo-q5_0.bin

The companion listens on TCP port 45679. The terminal prints the temporary
pairing code and full TLS certificate fingerprint. Enter these on the phone.

This is a development bundle, not a validated release package. Windows,
GNOME Wayland and KDE Wayland desktop input are not supported in this build.
