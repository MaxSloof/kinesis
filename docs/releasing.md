# Releasing

Releases are built by GitHub Actions (`.github/workflows/release.yml`) and
published to GitHub Releases. Currently it produces:

| Platform | Artifacts |
| --- | --- |
| Linux (x64) | `kinesis-<version>-linux-x64.tar.gz`, `kinesis-<version>-linux-amd64.deb` |
| macOS | `kinesis-<version>-macos.dmg` (unsigned, Apple Silicon) |
| Android | `kinesis-<version>-android.apk` (universal, release-signed) |

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

## Android signing (one-time setup)

Android only installs an update over an existing app if both APKs are signed
with the same key, so every release must use the same keystore.

1. Generate a keystore (keep it out of the repo, `*.jks` is git-ignored):

   ```sh
   keytool -genkey -v -keystore kinesis-release.jks -keyalg RSA -keysize 2048 \
     -validity 10000 -alias kinesis
   ```

2. Add these repository secrets (Settings → Secrets and variables → Actions):

   | Secret | Value |
   | --- | --- |
   | `ANDROID_KEYSTORE_BASE64` | `base64 -w0 kinesis-release.jks` (on macOS: `base64 -i kinesis-release.jks`) |
   | `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
   | `ANDROID_KEY_ALIAS` | `kinesis` (the alias used above) |
   | `ANDROID_KEY_PASSWORD` | the key password |

3. **Back up the keystore and passwords somewhere safe.** If they are lost,
   existing users must uninstall and reinstall the app (losing its data).

CI behavior: on a tag build, missing secrets fail the Android job so a
debug-signed APK is never published. On a manual test run, missing secrets only
produce a warning and a debug-signed APK.

For a local release-signed build, create `android/key.properties` (git-ignored)
with `storeFile`, `storePassword`, `keyAlias` and `keyPassword`; `storeFile` is
relative to the `android/` directory. Without it, release builds use the debug
key.

### Installing with Obtainium

Users can add `https://github.com/MaxSloof/kinesis` in
[Obtainium](https://obtainium.imranr.dev/) to install the APK from GitHub
Releases and get updates. Keep one `.apk` per release, always release with the
same keystore, and always increase the build number. Obtainium ignores
pre-releases by default.

## Testing the build without releasing

Run **Actions → Release → Run workflow**. This builds all platforms and
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
- Windows and iOS are not built by CI yet.
- Android is only built for sideloading (GitHub Releases / Obtainium), not
  published to Google Play. It has not been tested on a device yet.
