# Go-Friendly Desktop and Android Stack Options

Research date: 2026-08-10

Issue: GitHub #3, "Research viable Go-friendly desktop and Android stack options"

## Question

Given a local-first app, a strong preference for Go, macOS-first desktop UX, no hosted backend requirement, and a later Android companion importer, which application stacks are viable and what trade-offs should inform the stack decision?

## Recommendation

Use a Go domain/core with a Wails desktop shell for the first macOS app, and plan the Android companion as a small native Android app that imports media/files into the same local data model or export format.

This is the best fit if the desktop app needs to feel polished on macOS without abandoning Go for application logic. Wails is explicitly a desktop framework for Go plus web technologies, provides native menus/dialogs/theming/runtime APIs, embeds production frontend assets into the binary, and uses the platform webview rather than bundling Chromium. It does not require a hosted backend.

Do not bet on one shared GUI across macOS desktop and Android unless UI consistency is more important than macOS quality. The options that maximize Go and Android reuse, especially Fyne and Gio, are weaker for native-feeling macOS UI. The options that maximize native macOS and Android quality, especially SwiftUI/AppKit plus Kotlin/Compose, reduce Go to a shared library or core process.

If the user rejects a webview UI entirely, the fallback should be a native macOS shell in SwiftUI/AppKit calling a Go core, with a later native Android importer. If the user wants a pure-Go prototype immediately, Fyne is the lowest-friction option, but it should be treated as a product-quality risk for a macOS-first desktop app.

## Localhost and No-Server Preference

A localhost/webview architecture does not automatically violate a local-first or no-hosted-backend preference. It violates the preference only if the app depends on an externally hosted service, exposes broad loopback APIs, or makes the browser/webview the authority over local data.

Wails production apps can bundle frontend assets into the Go binary through `embed.FS`; the Wails docs describe production builds as single executables with bundled assets and no external files. Wails development mode can expose a dev webserver and browser debugging, but that is development tooling, not a hosted backend requirement.

Tauri's default model also avoids localhost by using a custom protocol and IPC to Rust commands. Tauri has an explicit localhost plugin, but its own docs warn that it carries considerable security risks and should only be used if necessary. For this project, avoid optional localhost plugins unless a specific web API requires an HTTP origin.

The acceptable pattern is: local packaged assets, narrow IPC from UI to trusted Go/Rust/native code, no network listener in production unless deliberately scoped to loopback and justified.

## Comparison Matrix

| Option | Go Fit | macOS GUI Quality | Android Feasibility | File/Media Access | Packaging | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| Wails | Excellent for desktop core | Good if web UI is acceptable; native menus/dialogs help | Poor for shared Android app; Wails is desktop-focused | Good through Go backend plus native dialogs/runtime | Strong desktop CLI and native packages | Recommended desktop shell |
| Fyne | Excellent, pure Go | Medium; custom widgets, not truly AppKit | Good; official Android packaging | Decent Fyne URI/storage/dialog APIs; Android media edge cases still need native care | Simple desktop/mobile packaging | Good prototype, product UX risk |
| Gio | Excellent, pure Go | Medium-low for standard app UI; low-level immediate-mode UI | Good technically | Core storage/permissions exist but higher-level OS pickers/media workflows are DIY | `gogio` supports desktop/mobile | Best for custom canvas UI, not CRUD/media desktop |
| Tauri + Go core | Weak-medium; Rust is the app backend | Good webview desktop shell; strong native packaging | Good for Tauri itself, but Go core adds friction | Strong plugin/capability model; Rust-side file APIs | Strong desktop/mobile bundling | Viable only if Rust is acceptable |
| Flutter + Go core bindings | Medium; Dart UI, Go library | Medium-good; polished but not native AppKit | Excellent | Strong plugin ecosystem; Go binding adds complexity | Strong mobile/desktop deployment | Good if Android reuse dominates Go preference |
| Qt Go bindings | Medium; Go binding ecosystem risk | Good Qt-quality UI, not native AppKit | Good at Qt level | Strong Qt modules | Heavy; licensing/deployment complexity | Avoid unless Qt expertise already exists |
| Native macOS + native Android + Go core | Medium; Go as shared library/core | Best | Best | Best, via first-party APIs | Strong but two UI codebases | Best UX, highest platform work |

## Option Notes

### Wails

Wails v2 describes itself as a way to write desktop apps using Go and web technologies. It provides native menus, dialogs, theming, translucency, Windows/macOS/Linux support, Go-to-JavaScript method binding, TypeScript model generation, runtime APIs, and production native binaries. Its architecture is a standard Go app with a webkit frontend and bound Go methods exposed to frontend JavaScript. Production assets are supplied through embedded frontend assets; development mode can use live reload and a browser-accessible dev server.

Wails is a strong fit for a macOS-first desktop app if HTML/CSS UI is acceptable. It lets the app keep Go as the main application/core language and avoids Electron-scale bundled browsers by reusing platform webviews. It is not a good Android strategy: Wails v2 is desktop-focused, and Wails v3 installation docs list Windows, macOS, and Linux supported platforms. Treat Android as a separate companion app.

Sources: Wails introduction and features, Wails architecture/how-it-works, Wails project config, Wails v3 installation supported platforms.

### Fyne

Fyne is the strongest pure-Go cross-platform GUI candidate. Official docs show desktop packaging with `fyne package -os darwin` creating a `.app`, and mobile packaging with `fyne package -os android` creating an APK. Fyne provides file open/save/folder dialogs and a storage package around URI readers/writers, listing, copying, moving, creating, deleting, and repository-backed URI schemes.

The trade-off is macOS UX. Fyne's value is one Go codebase and simple packaging, not native AppKit fidelity. For a macOS-first app, Fyne is viable for internal tools, prototypes, or apps whose UI can tolerate a custom cross-platform look. It is less compelling if the desktop app needs native-feeling sidebars, toolbars, keyboard conventions, accessibility polish, sheets, media pickers, and system integration.

Sources: Fyne desktop packaging, Fyne mobile packaging, Fyne `dialog.FileDialog`, Fyne `storage` package.

### Gio

Gio is also Go-native and targets desktop, mobile, and WebAssembly. Its install docs say desktop builds work with the Go tool and mobile uses `gogio`; its `app` package provides platform-independent OS/window functionality. The API exposes `DataDir`, Android/iOS behavior, mobile storage permissions under `gioui.org/app/permission/storage`, and Android status/navigation bar options.

Gio is a better fit for custom immediate-mode visual tools than conventional desktop productivity UI. It has few dependencies and gives control, but that control means more work for native-feeling controls, complex lists/tables, file/media workflows, accessibility, and platform conventions. It is not the easiest route to a polished macOS-first local-first media app.

Sources: Gio install docs, `gioui.org/app` package docs.

### Tauri With Go Core

Tauri v2 builds desktop and mobile apps with a web frontend and Rust/Swift/Kotlin backend logic when needed. The command model is Rust-first: frontend code invokes Rust commands registered in `src-tauri/src/lib.rs`. Tauri has strong packaging and distribution docs for macOS, Windows, Linux, Android, and iOS, and a scoped filesystem plugin with explicit permissions and platform notes. The filesystem plugin notes Android access is restricted to the application folder by default and that external storage locations need Android permissions.

Tauri is attractive if the team accepts Rust as the shell/backend language and Go as a sidecar, C ABI library, or separate shared core. It is not Go-friendly in the same way Wails is. Adding Go increases architecture complexity because the natural extension points are Rust commands and Tauri plugins. The optional localhost plugin should be avoided for this project because Tauri's docs warn it carries considerable security risk and because the default custom protocol is a better fit for no-server preferences.

Sources: Tauri overview, Tauri calling Rust from frontend, Tauri filesystem plugin, Tauri distribution docs, Tauri localhost plugin.

### Flutter With Go Core Bindings

Flutter gives the best path to a high-quality Android companion while retaining a single UI technology across Android and desktop. Flutter officially supports Android, iOS, macOS, Windows, Linux, and web deployment. It provides platform channels for calling platform-specific code, with Android in Kotlin/Java, macOS in Objective-C, Windows in C++, and Linux in C. Platform channel messages are asynchronous and use standard codecs for JSON-like values and byte buffers. Flutter macOS deployment goes through the Xcode project/signing/App Store flow.

The Go fit depends on `gomobile bind` or C/FFI-style bindings. `gomobile bind` can generate Android AARs and Apple platform bindings/XCFrameworks for Go packages, but it is not a simple "Go app with Flutter UI" path. It makes Go a shared library with binding constraints. Choose Flutter if Android product quality and UI reuse outrank the desire to write the shell in Go.

Sources: Flutter supported platforms, Flutter platform channels, Flutter macOS deployment, Go `gomobile` docs.

### Qt Bindings

Qt itself is mature and has official Android support, including Qt for Android, Qt Quick for Android, Qt Quick Controls, Qt Multimedia, sensors, location, Bluetooth, network, APK/AAB/AAR packaging, and supported Android API/ABI configurations. Qt can produce high-quality cross-platform UIs, but native macOS fidelity is still Qt-style rather than AppKit-style.

The Go binding story is the weak point. The prominent `therecipe/qt` repository advertises broad platform support and near-complete Qt access, but its installation instructions use old `GO111MODULE=off` flows and it carries LGPLv3 licensing for the binding. That is a maintenance, licensing, and onboarding risk for a new product unless the team already has Qt expertise and is comfortable owning the binding risk.

Sources: Qt for Android docs, `therecipe/qt` README.

### Native Platform Approaches

Native macOS with SwiftUI/AppKit and native Android with Kotlin/Jetpack Compose give the best platform UX and the least friction for system file/media access. macOS can use first-party AppKit/SwiftUI APIs; Android can use first-party media and document access APIs such as the Photo Picker and Storage Access Framework. This is the strongest UX option and the safest long-term path for platform-specific media import behavior.

The cost is two UI codebases and less Go in the application shell. Go can still be used for a core library through `gomobile bind`, an XCFramework/AAR, a C ABI library, or a local command/service boundary, but each bridge adds constraints. This is the fallback if native macOS feel is non-negotiable or if webview UI is rejected.

Sources: Apple AppKit and SwiftUI docs, Android Photo Picker and document/file storage docs, Go `gomobile` docs.

## File-System and Media Access Implications

Desktop local-first storage is straightforward for Wails, Fyne, Gio, Tauri, Flutter, Qt, and native approaches because each can write app data locally and use platform packaging/signing models. The main difference is user-selected library/media access and long-term permissions.

On Android, media import should be designed as Android-native regardless of desktop stack. Modern Android media access is shaped by picker and document-provider flows, not arbitrary filesystem traversal. A later companion importer should use Android's Photo Picker or Storage Access Framework, copy selected media/metadata into app-owned storage or an export bundle, and pass a clean import artifact to the Go core. This avoids forcing the desktop GUI stack to solve Android permissions.

For macOS desktop, prefer native dialogs/runtime APIs for user-selected locations. Wails can expose Go filesystem logic behind native dialogs/runtime calls; Fyne has file dialogs and URI storage; Tauri has scoped filesystem capabilities; Flutter/Qt/native have platform plugin/native APIs. Sandboxed App Store distribution will add entitlements and user-consent constraints regardless of UI stack.

## Decision Guidance

Pick Wails if the target is a polished local-first macOS desktop app with Go as the main implementation language, and if a webview-rendered UI is acceptable.

Pick native SwiftUI/AppKit plus native Android if macOS feel, accessibility, and media/system integration outrank Go-in-the-shell and single-codebase goals.

Pick Fyne if speed, pure Go, and Android packaging matter more than native macOS fidelity.

Pick Flutter if Android UI quality and sharing one UI framework across desktop/mobile matter more than keeping the app shell in Go.

Avoid Gio unless the app is closer to a custom graphics/canvas tool than a standard desktop productivity/media-management app.

Avoid Qt Go bindings unless Qt is already a known dependency and the team accepts binding and licensing risk.

Avoid Tauri-with-Go-core unless Rust is acceptable as a first-class application layer; otherwise Wails is the more Go-friendly webview shell.

## Sources

- Fyne, "Packaging for Desktop": https://docs.fyne.io/started/packaging/
- Fyne, "Mobile Packaging": https://docs.fyne.io/started/mobile/
- Fyne, `dialog.FileDialog`: https://docs.fyne.io/api/v2/dialog/filedialog/
- Fyne, `storage` package: https://docs.fyne.io/api/v2/storage/pkg/
- Gio, "Install": https://gioui.org/doc/install
- Gio, `gioui.org/app` package: https://pkg.go.dev/gioui.org/app
- Wails, "Introduction": https://wails.io/docs/introduction/
- Wails, "How does it work?": https://wails.io/docs/howdoesitwork/
- Wails, "Project Config": https://wails.io/docs/reference/project-config
- Wails v3, "Installation": https://v3.wails.io/getting-started/installation/
- Tauri, "What is Tauri?": https://v2.tauri.app/start/
- Tauri, "Calling Rust from the Frontend": https://v2.tauri.app/develop/calling-rust/
- Tauri, "File System": https://v2.tauri.app/plugin/file-system/
- Tauri, "Distribute": https://v2.tauri.app/distribute/
- Tauri, "Localhost": https://v2.tauri.app/plugin/localhost/
- Flutter, "Supported deployment platforms": https://docs.flutter.dev/reference/supported-platforms
- Flutter, "Writing custom platform-specific code": https://docs.flutter.dev/platform-integration/platform-channels
- Flutter, "Build and release a macOS app": https://docs.flutter.dev/deployment/macos
- Go, `gomobile` command: https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile
- Qt, "Qt for Android": https://doc.qt.io/qt-6/android.html
- `therecipe/qt` README: https://github.com/therecipe/qt
- Apple, AppKit documentation: https://developer.apple.com/documentation/appkit
- Apple, SwiftUI documentation: https://developer.apple.com/documentation/swiftui
- Android Developers, Photo Picker: https://developer.android.com/training/data-storage/shared/photopicker
- Android Developers, documents and files / Storage Access Framework: https://developer.android.com/training/data-storage/shared/documents-files
