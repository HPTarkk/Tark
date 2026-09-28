# Releasing Tark

## Cutting a release

```powershell
.\scripts\release-patch.ps1   # next patch: a new tag on the current release/<major>.<minor>.0
.\scripts\release-minor.ps1   # next minor: opens a new release branch from main
.\scripts\release-major.ps1   # next major: opens a new release branch from main
```

One run bumps `pubspec.yaml`, builds the `.aab` and the universal APK, signs the Bazaar `bin/` with the keystore named in `android/key.properties`, tags `v<version>`, pushes, creates the GitHub release with `Tarkk.apk`, then switches to `main` and merges the release branch back so `main` carries the new version. Nothing is pushed if the build or signing fails. Upload `build/release/<version>/Tarkk.aab` + `bin/` to Bazaar, and once it is live bump `website/update.json` (see README → App updates).

To hotfix an older line, check out its `release/*` branch, commit the fix there, and run `release-patch.ps1` from it — `main` is then left out of the release and not merged back.
