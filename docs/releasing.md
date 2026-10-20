# Releasing

Releases are built by GitHub Actions (`.github/workflows/release.yml`) and
published to GitHub Releases. Currently it produces:

| Platform | Artifacts |
| --- | --- |
| Linux (x64) | `kinesis-<version>-linux-x64.tar.gz`, `kinesis-<version>-linux-amd64.deb` |
| macOS | `kinesis-<version>-macos.dmg` (unsigned, Apple Silicon) |

## Versioning

`pubspec.yaml` is the single source of truth:

```yaml
version: 1.1.0+2
```

- `1.1.0` is the **version name**. Follow [semver](https://semver.org/):
  - patch (`1.0.1`): bug fixes only
  - minor (`1.1.0`): new backwards-compatible features
  - major (`2.0.0`): breaking changes
- `+2` is the **build number**. Increase it by one on every release, and never
  reuse or lower it. Android (`versionCode`) and the app stores require it to
  keep increasing.
- The git tag is `v` plus the version name, for example `v1.1.0`.
- CI does not override the version. It builds what `pubspec.yaml` says and
  fails the release if the tag does not match.

## Release steps

1. Make sure `main` is green: `flutter analyze` and `flutter test`.
2. Edit `version:` in `pubspec.yaml` (bump the name and the build number).
3. Update the "Platform versions" section in `README.md` to match.
4. Commit and push:

   ```sh
   git commit -am "Release 1.1.0"
   git push origin main
   ```

5. Tag that commit and push the tag:

   ```sh
   git tag v1.1.0
   git push origin v1.1.0
   ```

6. Watch the **Release** run in the Actions tab. When it finishes, the
   release appears under **Releases** with the installers attached and
   auto-generated notes. Edit the notes there if needed.

## Testing the build without releasing

Run **Actions → Release → Run workflow**. This builds both platforms and
uploads them as workflow artifacts, but does not create a release and skips
the tag check.

## Fixing a bad release

- **Tag doesn't match `pubspec.yaml`:** the run fails early. Delete the tag,
  fix the version, then tag again:

  ```sh
  git tag -d v1.1.0
  git push origin :refs/tags/v1.1.0
  ```

- **Broken release already published:** don't reuse the version. Fix the
  problem, bump to the next patch version and build number, and release again.
  Delete the broken release in the GitHub UI if needed.

## Known limitations

- macOS builds are not signed or notarized. On first launch, right-click the
  app and choose **Open**. Signing needs an Apple Developer account.
- The macOS build runs on Apple Silicon only (built on `macos-latest`).
- Windows, Android and iOS are not built by CI yet.
