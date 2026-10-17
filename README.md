# Kinesis

Kinesis is a lightweight, local-first desktop application for reviewing and
ingesting photos and other media from a camera card, USB drive, or folder into
a media library. It copies selected files, verifies each copy with SHA-256,
and can then move the source files to Trash.

Kinesis is under active development. This repository currently provides macOS
and Linux desktop projects; other platforms are not currently documented or
tested as supported targets.

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
| Other images | `.png`, `.heic`, `.gif` |
| Video | `.mp4`, `.mov` |

JPEG and CR3 files with the same name in the same folder are treated as a
paired shot. Kinesis displays image previews where the desktop image decoder
supports them and can extract a preview JPEG embedded in a CR3. Video files
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
   folder. Kinesis scans it recursively.
2. Choose a destination library folder with **Set library**. The library can
   be on a local or mounted volume.
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
| `{year}` | Four-digit year from the source file's last-modified timestamp |
| `{month}` | Two-digit month from the same timestamp |
| `{day}` | Two-digit day from the same timestamp |
| `{originalName}` | Original filename, including its extension |
| `{sourceFolder}` | Name of the folder containing the source file |

For example, with the default template and a source file last modified on
October 17, 2026, Kinesis imports it into `2026/2026-10-17/`. The folder date
uses the file's last-modified timestamp; it is not necessarily the photo's
EXIF capture date.

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

**Confirming the plan can move source files to Trash.** For an item with a
JPEG/CR3 pair, the decision determines what is imported, but all source files
in that pair are included in cleanup. For example, **Keep JPEG** imports the
JPEG and moves both the JPEG and CR3 source files to Trash. Duplicate source
files are also included in cleanup by the default duplicate decision. Check
the plan before confirming, and keep another backup of important media.

Kinesis uses the system Trash where available. If that fails, it places files
in a `.kinesis-trash/<date>/` holding folder on the source volume, preserving
their relative paths. This fallback is not the same as permanent deletion;
you can inspect that folder and restore files manually.

## Local data

Kinesis stores settings and its app-level record of imported assets in the
operating system's application-support directory. It also maintains a
`.kinesis/index.json` hash index in the library to speed up duplicate checks;
this index is rebuildable from the media files. Media remains in the folders
you choose—Kinesis does not require a separate cloud service or proprietary
library database.

## Development

The app is a Flutter project. Main application code is in `lib/`, with tests
in `test/`. Useful commands:

```sh
flutter analyze
flutter test
```

See [Flutter's documentation](https://docs.flutter.dev/) for framework and
desktop development guidance.
