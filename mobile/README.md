# Nexus Remote mobile

Flutter app with Remote, Write and Media sections for a desktop computer running
the Nexus Remote companion.

The TV remote that used to be the **TV** section is now its own app, **Nexus TV**,
in the Imac repo (`~/Imac/mobile`, built with `scripts/build-phone-app.sh` there).
It keeps the `com.nexus.tv` id and signing key, so it updates the earlier Nexus TV
APK built from this repo's former `tv` flavor.

## Build and checks

```sh
flutter pub get
flutter analyze
flutter test
```

On this shared filesystem `gradlew` cannot keep its executable bit. Build the
release APK from a copy on the Linux disk with `bash ../scripts/build-android.sh`
(writes `dist/nexus-remote-<version>-android.apk`), or from `mobile/`:

```sh
JAVA_HOME=/home/obada/android-studio/jbr bash android/gradlew -p android :app:assembleDebug
```

## iPhone

The `ios/` runner uses the same Flutter code. It declares local-network and
microphone access for dictation; it has not been built or tested on iOS from this
Linux workstation.
