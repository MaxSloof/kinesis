---
name: release
description: Cut a new Kinesis release. Use when the user asks to release, publish, tag, bump the version, or ship a new version of the app.
---

# Release Kinesis

`pubspec.yaml` is the single source of truth for the version. CI
(`.github/workflows/release.yml`) builds Linux (`.tar.gz`, `.deb`) and macOS
(`.dmg`) installers when a `v<version>` tag is pushed, and attaches them to a
GitHub Release. The tag must equal `v` + the version name in `pubspec.yaml`, or
CI fails. Full reference: `docs/releasing.md`.

## Steps

1. **Check state.** Run `git status` and `git branch --show-current`. Work should
   be committed and on `main`. If there are unrelated uncommitted changes, ask
   the user before continuing.
2. **Verify.** Run `flutter analyze` and `flutter test`. Stop on failures.
3. **Choose the version.** Read the current `version:` in `pubspec.yaml`. Ask the
   user which bump applies (semver: patch for fixes, minor for features, major
   for breaking changes) unless they already said.
4. **Bump.** Set `version: <name>+<build>` in `pubspec.yaml`. The build number
   must increase by exactly one, never reuse or lower it.
5. **Sync docs.** Update the "Platform versions" section in `README.md` to the
   new version and build.
6. **Commit.** `git commit -am "Release <name>"` (only the release files).
7. **Confirm before publishing.** Show the user the version, tag, and commit,
   and get explicit approval. Do not push without it.
8. **Push and tag.**
   ```sh
   git push origin main
   git tag v<name>
   git push origin v<name>
   ```
9. **Verify the run.** `gh run list --workflow=Release --limit 1`, then
   `gh run watch` or `gh run view`. Report the result and the release URL
   (`gh release view v<name> --web` or `--json url`).

## Failure handling

- **Tag/version mismatch:** delete the tag and re-tag after fixing.
  ```sh
  git tag -d v<name>
  git push origin :refs/tags/v<name>
  ```
- **Broken published release:** never reuse the version. Fix the issue, bump to
  the next patch version and build number, release again, and delete the broken
  release if the user wants.
- **Dry run without releasing:** `gh workflow run Release` builds artifacts
  without creating a release.

## Known limitations

- macOS builds are unsigned and not notarized, and Apple Silicon only.
- Windows, Android, and iOS are not built by CI yet.
