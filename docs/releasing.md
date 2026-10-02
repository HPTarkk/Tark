# Releasing Tark

## Cutting a release

```powershell
.\scripts\release-patch.ps1   # next patch: a new tag on the current release/<major>.<minor>.0
.\scripts\release-minor.ps1   # next minor: opens a new release branch from main
.\scripts\release-major.ps1   # next major: opens a new release branch from main
```

One run bumps `pubspec.yaml`, builds the `.aab` and the universal APK, signs the Bazaar `bin/` with the keystore named in `android/key.properties`, tags `v<version>`, pushes, creates the GitHub release with `Tarkk.apk`, then switches to `main` and merges the release branch back so `main` carries the new version. Nothing is pushed if the build or signing fails. With a Pishkhan token (below), the run then uploads `Tarkk.aab` + `bin/` to Bazaar as a draft and waits until Bazaar has processed it; without one, upload `build/release/<version>/Tarkk.aab` + `bin/` in the Bazaar panel by hand. Once the release is live, bump `website/update.json` (see README → App updates).

## Bazaar through Pishkhan

`scripts/bazaar-pishkhan.ps1` talks to Cafe Bazaar's Pishkhan API. The token comes from `.PISHKHAN` at the repo root (one line, gitignored; get it in the Bazaar panel under the app → "API پیشخان") or from the `PISHKHAN_API_TOKEN` environment variable. It is a real secret: it can upload builds and send them for review.

```powershell
.\scriptsazaar-pishkhan.ps1 status          # last published, last committed, current draft
.\scriptsazaar-pishkhan.ps1 upload 1.1.1    # draft from build\release\1.1.1 (create, .aab, .bin, wait)
.\scriptsazaar-pishkhan.ps1 commit          # send the draft for review (asks for the changelogs)
.\scriptsazaar-pishkhan.ps1 delete          # delete the draft; only possible before commit
```

The release run only ever leaves a draft. Sending it for review is always `commit`, which shows the draft and changelogs and needs `send` typed back. It takes `-ChangelogFa`, `-ChangelogEn`, `-DeveloperNote` (for Bazaar's reviewers), `-Rollout <1-100>` (staged rollout, default 100) and `-AutoPublish` (go live as soon as review passes; without it you press "publish" in the panel after review). If Bazaar already holds a draft, `upload` asks before deleting it (`-ReplaceDraft` skips the question). A failed upload during a release only warns: rerun `upload <version>` without rebuilding.

Bazaar processes the bundle after the `.bin` arrives and asks to be polled at most once a minute, so `upload` can take several minutes. The token belongs to one app; a 403 means the token is wrong or for another app.

To hotfix an older line, check out its `release/*` branch, commit the fix there, and run `release-patch.ps1` from it — `main` is then left out of the release and not merged back.
