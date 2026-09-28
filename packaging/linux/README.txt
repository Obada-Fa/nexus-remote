Nexus Remote Linux/X11 development bundle

Requirements: x86_64 Linux with an X11 desktop session, glibc and libstdc++,
playerctl, pactl, a PulseAudio-compatible audio service, and a session D-Bus.

Install the default model separately:
    python3 models/install.py quality

Then start from the logged-in X11 session:
    ./run.sh

The companion listens on TCP port 45679. The terminal prints the temporary
pairing code and full TLS certificate fingerprint. Enter these on the phone.

This is a development bundle, not a validated release package. Windows,
GNOME Wayland and KDE Wayland desktop input are not supported in this build.
