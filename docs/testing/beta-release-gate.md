# Tark beta release gate

This checklist separates automated repository health from physical beta acceptance. A green GitHub Actions run is required for merge, but it is never evidence that hotspot, Bluetooth, headset, screen-off, or motorcycle behavior passed on real hardware.

## Local parity before a PR

Use the repository's pinned/supported Flutter toolchain and run:

```bash
flutter pub get
flutter gen-l10n
dart format --output=none --set-exit-if-changed <changed-dart-files>
flutter analyze
flutter test
python3 scripts/test_decode_tark_log.py
node scripts/build-website-i18n.mjs --check
flutter build apk --debug

git diff --check
```

The CI workflow additionally discovers and runs protocol/packet/codec compatibility tests as a dedicated gate. New wire-format work must add mixed-version/golden coverage rather than relying only on the full unit suite.

## What CI proves

The required `Tark beta quality gate` checks:

- changed Dart files conform to the pinned formatter;
- static analysis is clean;
- Flutter unit/widget tests pass;
- Tark log analyzer tests pass;
- website localization output is current;
- protocol compatibility tests exist and pass;
- the Android debug application compiles with CI build provenance;
- the final diff has no whitespace errors.

The workflow token is read-only (`contents: read`). It does not receive signing material and does not publish a release.

## What CI does not prove

Before a beta candidate can be accepted, record real-device evidence for the scenarios maintained in the motorcycle/physical regression runbooks, including as applicable:

- 2-, 3-, and 5-device rooms;
- hotspot host/join, late join, leave/rejoin, and forced hotspot loss;
- screen off/on and background recovery;
- VPN enabled on host and joiner;
- Bluetooth/helmet-headset routing;
- Shared Music start/stop, receiver health, and capture-blocked behavior;
- bidirectional audibility after recovery;
- Persian/RTL primary flows;
- soak testing with exported `.tarklog` evidence.

Never mark a physical scenario passed from emulator, unit-test, or CI evidence.

## Build provenance

CI compile checks inject `BUILD_CHANNEL=ci` and the GitHub commit SHA. Beta/release tooling must likewise inject the exact source commit and build channel; when available it should also inject the build timestamp and clean/dirty state. A semantic version without an exact commit is not sufficient field evidence.

## Release boundary

Merging code is separate from releasing it. Version changes, the PowerShell release/versioning script, signing builds, APK/AAB distribution, tags, GitHub Releases, deployment, and publishing are deliberate release-owner actions and are not part of this quality-gate workflow.
