# Android device-test APK from a phone

Tark has two Android build paths:

1. **Release builds** — production-signed APK/AAB, cut locally with the `scripts/release-*.ps1` scripts (see [releasing.md](releasing.md)). The signing key never leaves the release machine.
2. **Build Tark Android Device-Test APK** — a debug-signed test APK that needs no production signing secret and can be started entirely from GitHub on a phone.

## Get a device-test APK from Android

1. Open the Tark repository on GitHub.
2. Open **Actions**.
3. Select **Build Tark Android Device-Test APK**.
4. Tap **Run workflow** and keep `main` selected.
5. Open the completed run.
6. Download the `tark-device-test-<commit>` artifact.
7. Unzip it in Android Files/My Files and install the `.apk` inside.

The device-test build uses application id `com.b1101.tark.dev`, so it installs beside the production Tark application instead of replacing it. Its diagnostic build metadata also records the exact Git commit.

GitHub Actions uses a runner-generated debug signing key for this test-only package. If Android refuses to update an older Tark device-test build because its debug signer changed, uninstall only the `com.b1101.tark.dev` test app and install the new test APK. This does not require uninstalling the production Tark app.
