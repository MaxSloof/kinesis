# Research: macOS Mounted-Media Detection and Import Permissions

Date: 2026-08-10

Issue: [#5 Research macOS mounted-media detection and import permissions](https://github.com/MaxSloof/kinesis/issues/5)

## Question

What are the practical macOS APIs, permissions, sandboxing constraints, and packaging implications for detecting mounted SD cards, USB drives, and local folders, then copying and verifying media from them in a local desktop app?

Focus: constraints relevant to a Go-friendly macOS-first desktop app.

## Executive Summary

For Kinesis, the safest Go-friendly design is: let the user explicitly choose a source folder or mounted volume, persist that access with a security-scoped bookmark if the app is sandboxed, copy files into an app-controlled library/staging area, verify the copied bytes, and treat automatic mount detection only as a convenience hint.

macOS has good native APIs for volume detection, but most are Cocoa/Core Foundation APIs that require cgo or a small native helper from Go. Disk Arbitration can notify when disks appear or disappear, but Apple explicitly says sandboxed apps can only use those notifications in a limited way unless they already have a security-scoped bookmark to a file on the newly inserted media. That makes fully automatic SD-card import a poor primary workflow for a sandboxed app. User intent through `NSOpenPanel`/Powerbox should be the core permission boundary.

If Kinesis is distributed outside the Mac App Store, it can remain non-sandboxed, notarized, and hardened-runtime signed. That materially simplifies source detection and file copying, but it also loses App Sandbox's protection and may still encounter macOS privacy prompts or normal file-system permissions. If Mac App Store distribution is a goal, design as sandbox-first from the beginning.

## Primary Source Notes

### Volume Discovery APIs

Apple's Disk Arbitration Programming Guide says the Disk Arbitration framework can detect when disks appear, prevent mounting, mount with different flags or mount points, unmount volumes, and watch volume-name changes. It is a low-level Core Foundation framework intended for apps that handle unknown media or monitor/manipulate volume mounting. Source: [Apple Disk Arbitration Programming Guide, About Disk Arbitration](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/Introduction/Introduction.html).

The same Apple guide includes the important sandbox note: the document is primarily for utility-style apps that are not sandboxed; sandboxed apps can still register for disk appear/disappear notifications, but their ability to use those notifications is limited unless they have a security-scoped bookmark to a file on the newly inserted media. Source: [Apple Disk Arbitration Programming Guide, App Sandbox Note](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/Introduction/Introduction.html).

Foundation exposes volume enumeration through `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options:)`, and URL resource keys include volume properties such as `volumeIsRemovableKey`, `volumeIsEjectableKey`, and `volumeIsInternalKey`. These are current Apple Developer Documentation pages, though they require JavaScript in this environment. Sources: [FileManager mounted volume URLs](https://developer.apple.com/documentation/foundation/filemanager/mountedvolumeurls%28includingresourcevaluesforkeys%3Aoptions%3A%29), [volumeIsRemovableKey](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeisremovablekey), [volumeIsEjectableKey](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeisejectablekey), [volumeIsInternalKey](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeisinternalkey).

AppKit's `NSWorkspace` publishes workspace notifications such as volume mount/unmount notifications, and is the Cocoa-level path for GUI apps that already depend on AppKit. Source: [NSWorkspace current documentation](https://developer.apple.com/documentation/appkit/nsworkspace).

The File System Events API is for notifications when the contents of a directory hierarchy are modified, and is intended for apps working with large numbers or hierarchies of files. It is useful after a source folder is selected, but it is not the primary API for discovering newly mounted volumes. Source: [Apple File System Events Programming Guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/Introduction/Introduction.html).

### File Access and Sandboxing

Apple's File System Programming Guide says macOS file-system access is controlled by UNIX permissions, POSIX ACLs, BSD flags, and sandbox entitlements. If the app's sandbox forbids requested access, access is denied before normal file permissions can grant it. Source: [Apple File System Programming Guide, macOS File System Security](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemDetails/FileSystemDetails.html).

Apple's Entitlement Key Reference describes App Sandbox as a two-step model: enabling the sandbox removes most capabilities for interacting with the system, then entitlements restore specific capabilities. If a target lacks an entitlement for a required capability or resource, `sandboxd` logs a violation. Source: [Apple Entitlement Key Reference, Enabling App Sandbox](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

For user-selected files and folders, Apple says enabling `com.apple.security.files.user-selected.read-only` or `com.apple.security.files.user-selected.read-write` grants programmatic access to files and folders the user opens with `NSOpenPanel` or saves with `NSSavePanel`. Other direct user interactions, such as dragging items to the app, can also expand the sandbox to include those items. Source: [Apple Entitlement Key Reference, Enabling User-Selected File Access](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

For persistent access in a sandboxed app, Apple says the app must enable security-scoped bookmark and URL access with `com.apple.security.files.bookmarks.app-scope` or `com.apple.security.files.bookmarks.document-scope`. Source: [Apple Entitlement Key Reference, Enabling Security-Scoped Bookmark and URL Access](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

Apple's File System Programming Guide recommends using standard Open and Save panels for user interactions with the macOS file system, and says bookmarks are the persistent form for locating files between launches because path-based and file-reference URLs can be fragile. Source: [Apple File System Programming Guide, Accessing Files and Directories](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/AccessingFilesandDirectories/AccessingFilesandDirectories.html).

Temporary file-access exceptions exist for sandboxed macOS apps, but Apple documents them as temporary exceptions and says App Store Connect guidance requires identifying the entitlement and issue number and explaining why the app needs it. This is not a good foundation for normal mounted-media ingest. Source: [Apple Entitlement Key Reference, App Sandbox Temporary Exception Entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html).

### Hardware and USB Entitlements

The App Sandbox USB entitlement `com.apple.security.device.usb` enables interaction with USB devices using USB device access APIs. For media import, Kinesis should not need raw USB access if the SD card or USB drive is mounted as a file-system volume. File-system access should be handled through user-selected file access and bookmarks instead. Source: [Apple Entitlement Key Reference, Enabling Hardware Access](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

Disk Arbitration operates at the disk/volume layer, not by requiring raw USB access for normal mounted-volume enumeration. Source: [Apple Disk Arbitration Programming Guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/Introduction/Introduction.html).

### Supported File Systems and Media Reality

Apple documents that macOS supports common removable-media file systems including FAT and ExFAT, and identifies ExFAT as an interchange format used by digital cameras and other peripherals. Source: [Apple File System Programming Guide, Supported File Systems](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemDetails/FileSystemDetails.html).

Normal file-system permissions still matter on removable and network volumes. Apple notes administrators can disable ownership and permissions checking for removable volumes with Finder's "Ignore ownership on this volume" option. Source: [Apple File System Programming Guide, macOS File System Security](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemDetails/FileSystemDetails.html).

### Copying and Verification

Go's `os` package provides portable file operations, while system-specific features are in lower-level packages. `os.File` methods are documented as safe for concurrent use, although the OS may limit the number of concurrent operations. Source: [Go `os` package documentation](https://pkg.go.dev/os).

Apple recommends secure file operations: check result codes, know whether APIs follow symbolic links, verify that files being read or written are the files expected, and use file-descriptor-based routines where possible when working in directories not exclusively controlled by the process. Source: [Apple File System Programming Guide, Use Secure Coding Practices](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/AccessingFilesandDirectories/AccessingFilesandDirectories.html).

Apple warns that enumerating directories can touch large numbers of files and become expensive; enumeration should be used sparingly and preferably with resource keys prefetched when using Cocoa APIs. Source: [Apple File System Programming Guide, Enumerating the Contents of a Directory](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/AccessingFilesandDirectories/AccessingFilesandDirectories.html).

## Go-Friendly Implementation Options

### Option A: User-Selected Source First

This should be the default architecture.

Use a macOS open-folder panel to let the user select either a mounted volume root, a DCIM folder, or any local folder. In a sandboxed build, include `com.apple.security.files.user-selected.read-only` for source access. If Kinesis needs to remember favorite sources or auto-resume imports after relaunch, also include `com.apple.security.files.bookmarks.app-scope` and persist a security-scoped bookmark.

From Go, the panel and bookmark operations require either cgo/Objective-C bindings or a small native shim. Once the app has an authorized path, the scanning, copying, hashing, and verification pipeline can be ordinary Go using `os`, `io`, `crypto/*`, `path/filepath`, and careful error handling.

Why this fits macOS: it follows Apple's user-intent model and works both sandboxed and non-sandboxed.

### Option B: Native Volume Detection as a Convenience Layer

Use Disk Arbitration, Foundation `FileManager`, or AppKit `NSWorkspace` to discover or notify about mounted volumes. Present candidate sources in the UI, but expect the user to authorize a source before import if sandboxed.

From Go, Disk Arbitration is a C/Core Foundation framework, so direct use requires cgo and Core Foundation run-loop integration. AppKit/Foundation options require Objective-C bridging. A small macOS-specific helper package or helper process is preferable to spreading cgo through the import pipeline.

Why this is not enough alone: Apple's Disk Arbitration sandbox note means detection does not imply useful read access in sandboxed apps.

### Option C: Pure-Go Polling of `/Volumes`

For a non-sandboxed app, a simple polling layer can enumerate `/Volumes`, stat entries, and infer candidates by mount path and file-system metadata. This can be implemented mostly in Go, possibly with `golang.org/x/sys/unix` for Darwin-specific `statfs`/mount metadata.

This is attractive for an early personal tool, but it is less aligned with sandboxed distribution and less precise than native volume APIs. It should not be the only design if Mac App Store distribution remains possible.

## Recommended Ingest Permission Model

1. Treat source authorization as explicit user intent.
2. Let the user choose a mounted volume or folder with an open-folder panel.
3. For sandboxed builds, request read-only user-selected file access for sources.
4. Persist source access only with app-scoped security-scoped bookmarks.
5. Request destination/library access separately, likely read-write if user-selected outside the app container.
6. Copy into a staging area in the destination library.
7. Verify the copy before marking the item imported.
8. Do not offer source cleanup until verification succeeds.
9. Require a second explicit confirmation before deleting source files.
10. Prefer not to delete from camera cards in MVP; deletion requires read-write source access and raises the cost of mistakes.

## Packaging Implications

For Mac App Store compatibility, assume App Sandbox is required and design around user-selected folder access plus security-scoped bookmarks. Avoid relying on temporary file-access exceptions for mounted media.

For direct distribution, Kinesis can be non-sandboxed but should still be Developer ID signed, hardened-runtime enabled, and notarized. Apple provides current documentation for Hardened Runtime and notarization. Sources: [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime), [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Entitlements are embedded in an app's code signature, so packaging and signing need to be part of the build pipeline rather than an afterthought. Source: [Apple Entitlement Key Reference, About Entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AboutEntitlements.html).

If using cgo for Disk Arbitration/AppKit/Foundation, the release pipeline must build a real `.app` bundle with proper `Info.plist`, code signing, entitlements, and notarization/stapling for direct distribution. A raw terminal binary is useful for prototypes but does not exercise the same user-intent, sandbox, and packaging behavior as the desktop app.

## Design Constraints for Kinesis

Mounted-media detection should be advisory, not authoritative. The user must be able to manually pick a source folder even if automatic detection misses it.

The domain model should distinguish:

- `DetectedVolume`: a mounted volume candidate discovered by the system.
- `AuthorizedSource`: a user-approved folder/volume path or bookmark that Kinesis may read.
- `ImportSession`: a copy-and-verify run from one authorized source into one library destination.
- `StagedCopy`: bytes copied to a temporary or staging path but not yet committed.
- `VerifiedAsset`: an imported file whose destination bytes match the source according to the chosen verification policy.

The import pipeline should not depend on Cocoa objects after authorization. Convert native URLs/bookmarks into a small internal source handle, then let Go own traversal, filtering, copying, checksumming, progress, cancellation, and resumability.

Detection should degrade gracefully:

- If Disk Arbitration is available, show newly mounted removable/ejectable candidates.
- If native detection fails, allow manual folder selection.
- If a bookmark is stale or inaccessible, prompt the user to reselect the source.
- If source media disappears mid-import, stop cleanly, preserve copied staging state if useful, and report which files were verified.

## Open Implementation Questions

The research supports these decisions, but implementation still needs product choices:

- Whether MVP is sandbox-first or direct-distribution-first.
- Whether source cleanup is in MVP or deferred.
- Which verification policy to use: byte-for-byte reread, cryptographic hash, size plus hash, or source/destination hash manifest.
- Whether the library destination lives inside the app container by default or is a user-selected folder.
- Whether the native macOS bridge is embedded via cgo, generated bindings, or a small helper process.

## Sources

- [Apple Disk Arbitration Programming Guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/Introduction/Introduction.html)
- [Apple File System Programming Guide: Accessing Files and Directories](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/AccessingFilesandDirectories/AccessingFilesandDirectories.html)
- [Apple File System Programming Guide: File System Details](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemDetails/FileSystemDetails.html)
- [Apple File System Events Programming Guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/Introduction/Introduction.html)
- [Apple Entitlement Key Reference: About Entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AboutEntitlements.html)
- [Apple Entitlement Key Reference: Enabling App Sandbox](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)
- [Apple Entitlement Key Reference: Temporary Exception Entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
- [Apple Developer Documentation: Disk Arbitration](https://developer.apple.com/documentation/diskarbitration)
- [Apple Developer Documentation: FileManager mounted volume URLs](https://developer.apple.com/documentation/foundation/filemanager/mountedvolumeurls%28includingresourcevaluesforkeys%3Aoptions%3A%29)
- [Apple Developer Documentation: URL volume resource keys](https://developer.apple.com/documentation/foundation/urlresourcekey)
- [Apple Developer Documentation: NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)
- [Apple Developer Documentation: Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Apple Developer Documentation: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Go standard library: os package](https://pkg.go.dev/os)
- [Go x/sys/unix package](https://pkg.go.dev/golang.org/x/sys/unix)
