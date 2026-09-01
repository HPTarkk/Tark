# Releasing Tark

Use the **Release Tark** workflow from GitHub Actions. It is designed to be started from a phone or browser and runs only from `main`.

## One-time setup

Add these repository secrets in **Settings → Secrets and variables → Actions → Repository secrets**. Reuse the existing Tark Android keystore; never create a new signing key for an already installed app.

| Secret | Value |
| --- | --- |
| `TARK_ANDROID_KEYSTORE_BASE64` | Base64 encoding of the existing `.jks` keystore |
| `TARK_ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `TARK_ANDROID_KEY_ALIAS` | Alias of the existing signing key |
| `TARK_ANDROID_KEY_PASSWORD` | Key password |

The GitHub Actions bot must be allowed to push to `main`, because a successful release commits its generated version bump to `pubspec.yaml`.

## From a phone

1. Open **Actions → Release Tark → Run workflow**.
2. Keep the branch as `main`.
3. For the first device-test build choose `promote` + `beta`.
4. Add short release notes and run it.
5. When it succeeds, open **Releases** and download the `arm64-v8a.apk` asset for modern Android phones.

The release also includes an `.aab` for Play Console, SHA-256 checksums, and a guest-PWA ZIP. The PWA ZIP is intentionally not auto-deployed: production `app.tarkk.ir` remains under its current deployment ownership.

## Version behavior

- `promote` + `beta`: creates the next beta; a current beta becomes beta.2, beta.3, and so on.
- `promote` + `stable`: turns the current beta into its matching stable version. From a stable version it creates the next patch.
- `patch`, `minor`, or `major`: starts that new version on the selected channel.
