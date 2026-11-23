<p align="center">
  <img src="kinesis_v1.svg" alt="Kinesis logo" width="160">
</p>

# Kinesis

Kinesis is a lightweight, local-first desktop application for reviewing and
ingesting photos and other media from a camera card, USB drive, or folder into
a media library. It copies selected files, verifies each copy with SHA-256,
and can then move the source files to Trash.

Kinesis is under active development. This repository provides macOS, Linux and
Windows desktop projects plus Android and iOS projects. Only macOS has been
tested so far; the other platforms are untested.

### Platform versions

The current app version is **0.1.0** (build **1**) on each platform. These
values come from `pubspec.yaml` and are used for all platform builds. See
[docs/releasing.md](docs/releasing.md) for the release process.

| Platform | Version | Build |
| --- | --- | --- |
| Android | 0.1.0 | 1 (`versionCode`) |
| iOS | 0.1.0 | 1 |
| Linux | 0.1.0 | 1 |
| macOS | 0.1.0 | 1 |
| Windows | 0.1.0 | 1 |

## Features

- Review a source folder in single-image or grid view, with sorting and date
  grouping.
- Pair same-named JPEG and Canon CR3 files for review, and use an embedded CR3
  preview when a matching JPEG is unavailable.
- Detect exact duplicates in the destination library using SHA-256 hashes.
- Choose which files to import, including whether to keep JPEG, CR3, or both
  for a paired shot.
- Organize imported files with configurable destination templates, optionally
  keeping JPEG and CR3 files in separate folder trees.
- Browse media already in the library.
- Run ingest and browsing without a cloud account or hosted backend.

## Supported media

Kinesis scans these filename extensions (case-insensitively):

| Type | Extensions |
| --- | --- |
| JPEG | `.jpg`, `.jpeg` |
| Canon RAW | `.cr3` |
| Other images | `.png`, `.heic`, `.heif`, `.gif`, `.webp`, `.avif`, `.bmp`, `.tif`, `.tiff` |
| Other RAW (paired like CR3) | `.dng`, `.cr2`, `.nef`, `.nrw`, `.arw`, `.srf`, `.sr2`, `.raf`, `.orf`, `.rw2`, `.pef`, `.srw`, `.3fr`, `.iiq`, `.erf`, `.kdc`, `.mrw`, `.x3f` |
| Video | `.mp4`, `.mov` |

JPEG and RAW files with the same name in the same folder are treated as a
paired shot. Kinesis displays image previews where the desktop image decoder
supports them and can extract a preview JPEG embedded in a RAW. Video files
can be imported and listed, but video playback is not currently provided.

## Install and run

### Requirements

- [Flutter](https://docs.flutter.dev/get-started/install) with desktop support
  enabled for your operating system.
- A Dart SDK version satisfying this project's `^3.11.5` SDK constraint.
- macOS or Linux. For Linux, install the desktop development dependencies
  listed in [Flutter's Linux setup guide](https://docs.flutter.dev/platform-integration/linux/setup).

Check your Flutter installation and available desktop devices with:

```sh
flutter doctor
flutter devices
```

### Run from source

From the repository root:

```sh
flutter pub get
flutter run -d macos  # macOS
# or
flutter run -d linux  # Linux
```

To run the test suite:

```sh
flutter test
```

To create a desktop build:

```sh
flutter build macos  # macOS
# or
flutter build linux  # Linux
```

## Using Kinesis

1. Connect a camera card or other source drive, or choose a local source
   folder. Kinesis scans it recursively. On desktop, mounted volumes with a
   `DCIM` folder at their root appear as quick picks next to the folder picker;
   they are looked up when the screen opens and with the refresh button, not
   in the background. On Android, choose the folder in the
   system folder picker; Kinesis uses the granted Storage Access Framework
   access instead of raw `/storage/...` paths.
2. Choose a destination library folder with **Set library**. The library can
   be on a local or mounted volume. Android asks for a separate folder grant;
   the grant is retained across launches.
3. Review the scanned items. Use the single-image view to step through items,
   or switch to grid view to select several items and apply one decision to
   them together.
4. Choose **Keep both**, **Keep JPEG**, **Keep CR3**, or **Delete both** for
   each item you want to process. Items without a decision are left unchanged.
5. Select **Review plan**, read the counts of files to copy and source files to
   move to Trash, and confirm only when the plan is correct.

In single-image view, use the left and right arrow keys to navigate. The default
decision shortcuts are **A** (Keep both), **S** (Keep JPEG), **D** (Keep CR3),
and **F** (Delete both). You can change these letter shortcuts in **Settings**.
In grid view, click tiles to select them, Shift-click to extend a selection,
and double-click a tile to open it in single-image view.

### Duplicate behavior

Kinesis compares file contents using SHA-256, not just names. A matching file
already in the library is not copied a second time. Items containing a
duplicate default to **Delete both**; review that decision before confirming.
If only one half of a JPEG/CR3 pair is already in the library, you can change
the decision to import the missing half.

## Destination templates

Open **Settings** to set the folder structure for imported files. The default
template is:

```text
{year}/{year}-{month}-{day}
```

Templates accept these tokens:

| Token | Value |
| --- | --- |
| `{year}` | Four-digit year of the capture date |
| `{month}` | Two-digit month of the capture date |
| `{day}` | Two-digit day of the capture date |
| `{originalName}` | Original filename, including its extension |
| `{sourceFolder}` | Name of the folder containing the source file |
| `{shoot}` | Shoot name from **Import options** for this import; omitted when empty |
| `{camera}` | Camera make and model from EXIF or CR3 metadata, or `Unknown camera` |
| `{ext}` | Lower-case file extension without the dot, such as `cr3` |

`{shoot}` and `{camera}` are made safe for use as folder names: path separators
and characters like `: * ? " < > |` become `-`, and leading or trailing dots,
dashes and spaces are removed, so a name can't add folders or climb out of the
library. When no shoot name is set, `{shoot}` disappears together with the
separators (space, `-`, `_`, `.`, `,`) right after it, a folder left empty is
dropped, and separators left dangling at the end of a folder name are trimmed:
`{year}/{shoot} - {day}` becomes `2026/17`, not `2026/ - 17`.

The capture date is the first of these that is available: the EXIF
`DateTimeOriginal` (JPEG and other images), the capture date stored in a CR3's
metadata, a date in the file name (`IMG_20261017_143000`, `VID_…`, `DSC_…`,
`2026-10-17_14-30-00` or `2026-10-17-143000`), and finally the file's
last-modified time. A JPEG/CR3 pair uses one date, so both files land in the
same folder. For example, with the default template, a photo taken on
October 17, 2026 is imported into `2026/2026-10-17/`. Video dates come from the
file name or last-modified time; the MP4/MOV creation time is not read because
cameras disagree on whether it is UTC or local time. After a verified copy,
Kinesis sets the copy's last-modified time to the capture date (not on
Android); source files are never modified.

Open **Import options** in the review screen to name the shoot and, if the
camera clock or time zone was wrong, to set one fixed date and time for the
whole import or to shift every capture date by hours and minutes. The review labels, date groups, folders and
modified times of the copies use the adjusted dates, and the confirm dialog
says so. The setting applies to one import and is not saved.

Enable **Use separate JPEG and CRAW folders** to configure distinct templates
for JPEG and CR3 files. Their defaults are `JPEG/{year}/{year}-{month}-{day}`
and `CRAW/{year}/{year}-{month}-{day}`. Other supported media types continue
to use the general destination template. Templates must resolve to a location
inside the selected library.

## Import and source-file safety

Kinesis copies files to a staging area in the destination library and verifies
the copied bytes against the source using SHA-256 before placing the copy in
its destination folder. It does not delete a source file immediately after
copying it: source cleanup happens after the selected new files have been
copied and verified.

While importing, Kinesis shows files done out of total, bytes done out of
total and the current file. When you confirm the plan it first compares the
bytes to copy with the free space on the library volume and stops with a
message if there isn't enough. Free space is read with `df` on macOS and Linux;
on Android and Windows it can't be read, so the check is skipped.

**Confirming the plan can move source files to Trash.** For an item with a
JPEG/CR3 pair, the decision determines what is imported, but all source files
in that pair are included in cleanup. For example, **Keep JPEG** imports the
JPEG and moves both the JPEG and CR3 source files to Trash. Duplicate source
files are also included in cleanup by the default duplicate decision. Check
the plan before confirming, and keep another backup of important media.

Kinesis uses the system Trash where available. If that fails, it places files
in a `.kinesis-trash/<date>/` holding folder on the source volume, preserving
their relative paths. Android's Storage Access Framework does not expose a
system Trash operation, so Android always uses this holding folder. This is
not permanent deletion; you can inspect that folder and restore files manually.

## Local data

Kinesis stores settings and its app-level record of imported assets in the
operating system's application-support directory. It also maintains a
`.kinesis/index.json` index in the library that lists every media file with its
size and modified time. A file's SHA-256 is only calculated when it has the
same size as a file on the source, then stored in the index, so an ingest never
reads the whole library. Files whose path, size and modified time still match
reuse their stored hash. The index is a rebuildable cache: if it is missing,
damaged or from an unknown version, Kinesis rebuilds it. Duplicates are always
decided by full-content SHA-256. On Android, library hashes are calculated
through the selected folder grant and kept in memory rather than in an index
file. Media remains in the folders you choose—Kinesis does not require a
separate cloud service or proprietary library database.

## Development

The app is a Flutter project. Main application code is in `lib/`, with tests
in `test/`. Useful commands:

```sh
flutter analyze
flutter test
```

See [Flutter's documentation](https://docs.flutter.dev/) for framework and
desktop development guidance.

---

Built by [Max Sloof](https://maxsloof.nl).
