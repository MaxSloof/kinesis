# Kinesis

Kinesis is a local-first photo and media management application focused on lightweight ingest and library browsing workflows.

## Language

**Local-first app**:
A user-facing application whose core media workflows run on the user's device without requiring a cloud backend or hosted server-side component.
_Avoid_: Cloud app, server app

**Media library**:
The user's organized collection of imported photos and videos, browsed through folders or events with previews, basic metadata, and search or filtering.
_Avoid_: Catalog, database

**Ingest flow**:
A guided workflow that starts from a mounted source such as an SD card, USB drive, or local folder, lets the user review media, and imports selected files into the media library.
_Avoid_: Import job, upload flow

**Verified import**:
An import that copies selected media to the destination and verifies the copied files before any optional source cleanup is offered.
_Avoid_: Move, transfer

**Companion Android app**:
A later Android application that can import from phone storage into the same library model, rather than necessarily reproducing every desktop workflow.
_Avoid_: Android port, mobile version
