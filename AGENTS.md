## Agent skills

### Issue tracker

Issues are tracked in this repo's GitHub Issues via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

This repo uses the default canonical triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This repo uses a single-context domain-docs layout. See `docs/agents/domain.md`.

## Project overview

Kinesis is a local-first Flutter app for ingesting photos and media from a camera card or folder into a library. See `CONTEXT.md` for domain language and `README.md` for user-facing behavior.

- App code is in `lib/` (`domain/`, `services/`, `widgets/`, `main.dart`); tests are in `test/`.
- Platform projects: `macos/`, `linux/`, `windows/`, `android/`, `ios/`. Only macOS has been tested so far.

## Commands

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos   # or -d linux
```

Run `flutter analyze` and `flutter test` before considering a change done.

## Versioning and releases

- `pubspec.yaml` `version:` (`name+build`) is the single source of truth. Never override it in CI or hard-code versions elsewhere, except for the version table in `README.md`, which must be kept in sync.
- Releases are built by `.github/workflows/release.yml` when a `v<version>` tag is pushed; the tag must match `pubspec.yaml`.
- The build number must increase on every release.
- Full process: `docs/releasing.md`, or the `release` skill in `.opencode/skills/release/`.
- Never push tags or publish a release without explicit user confirmation.
