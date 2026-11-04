# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

MayloveE is a native macOS IDE for Java, written in Swift 6 + AppKit (SwiftPM package, macOS 14+, Apple Silicon). Language intelligence comes from jdtls (Eclipse JDT Language Server), syntax highlighting from tree-sitter (`SwiftTreeSitter` + `tree-sitter-java`, pinned with `exact:` versions), and Git from the `git` CLI. Keyboard shortcuts follow IntelliJ IDEA's macOS keymap.

## Commands

```bash
swift build                      # debug build
scripts/bundle.sh                # release build -> build/MayloveE.app (ad-hoc signed)
open build/MayloveE.app --args /path/to/java-project
scripts/release.sh               # self-contained DMG: downloads jdtls (sha256-checked), jlinks a JRE from JDK 25+ (JLINK_JDK)
```

Tests use Swift Testing (`@Test` / `@Suite`), not XCTest. This machine has only the Command Line Tools, so plain `swift test` fails to find the `TestingMacros` plugin; use:

```bash
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

Single suite/test: append `--filter GitRepositoryTests` or `--filter 'GitRepositoryTests/commitsOnlySelectedFilesIncludingUntracked'` (suite = struct name, not file name). Don't hardcode the plugin path in `Package.swift`.

Suites that launch jdtls or Maven (`JavaLanguageServerTests`, `RunControllerTests`) are gated with `.enabled(if: (try? JavaToolchain.locate()) != nil)` and are skipped silently when jdtls / a JDK 25+ isn't installed — a "pass" may mean they didn't run. They build throwaway Maven projects via `Tests/MayloveETests/TestJavaProject.swift`.

Before relaunching a new build, check `pgrep -fl "MayloveE.app/Contents/MacOS"`; if the app is running, ask the user to quit it (⌘Q shows the unsaved-changes prompt) instead of killing it.

## Architecture

Single executable target `Sources/MayloveE`; everything UI-facing is `@MainActor`. No storyboards/xibs — the menu is built in code (`MainMenu.swift`) and `AppDelegate.main()` starts `NSApplication` manually (also ignores `SIGPIPE` so writing to a dead jdtls doesn't kill the app). A folder path as first CLI argument opens it directly.

**One `WorkspaceWindowController` per opened folder** owns and wires everything for that workspace via closures (no notifications/DI framework): `FileTreeViewController` + `CommitViewController` in `SidebarViewController`, `EditorAreaViewController` (tabs + bottom console panel), `GitController`, a lazily created `JavaLanguageServer`, `RunController`, and a `FileWatcher` (FSEvents) that refreshes the tree, reloads unmodified editors, and re-reads git status on external changes.

**LSP (`LSP/`)**: `JavaToolchain.locate()` resolves (in order: env override → copies bundled in the app's `Contents/Resources/{jre,jdtls}` → installed) the Java 25+ that runs jdtls, the jdtls install (`~/Library/Application Support/MayloveE/jdtls/<version>/`, newest wins), and all JDKs from `/usr/libexec/java_home`, which are registered with jdtls so it picks the one matching the project's compiler level. `JavaLanguageServer` spawns one jdtls process per workspace; its `-data` dir and OSGi configuration area live under `~/Library/Caches/MayloveE/` keyed by SHA256 of the path (never inside the jdtls install, which may be read-only in the bundle). Notifications sent before `initialize` finishes are queued; callers `await waitUntilReady()`. Transport: `MessageFramer` → `JSONRPCConnection` with `JSONValue` as the untyped JSON model and `LSPTypes` for decoded types.

**Editor**: `EditorViewController` hosts `CodeTextView` (NSTextView subclass) with `LineNumberGutter` (also shows git change bars), `CompletionController`/`HoverController` (LSP-backed popups via `ListPopup`/`HoverRenderer`). `SyntaxHighlighter` colors only the visible range using layout-manager *temporary attributes*, so highlighting never touches text storage or the undo stack; edits within one run-loop turn coalesce into one reparse. `LineIndex` converts between LSP line/UTF-16 positions and string offsets.

**Run (`Run/`)**: `RunTarget` determines main class vs. test method/class at the caret. Main classes run directly with the project JDK and the classpath obtained from jdtls; tests run through Maven Surefire (`mvnw` if present, else `mvn`/`MAYLOVEE_MAVEN`) in the nearest `pom.xml` module (`BuildTools`). `BuildTools.processEnvironment` gives child processes the login shell's PATH. `RunSession` streams output via `UTF8StreamDecoder` into `ConsoleViewController`; `ConsoleLinks` turns compiler errors and stack-trace lines into clickable locations. A generation counter prevents a superseded run from starting.

**Git (`Git/`)**: `GitClient` runs `/usr/bin/git` (or `MAYLOVEE_GIT`) off the main thread with `GIT_TERMINAL_PROMPT=0` and `GIT_OPTIONAL_LOCKS=0`; failures surface stderr as the error. `GitRepository` wraps commands and parses `git status --porcelain=v2 --branch -z` in `GitStatus`; `GitController` drives the UI (tree/tab colors, commit window, rollback, branches, pull/push/fetch, log). `LineDiff`/`Diff/AlignedDiff` are in-house diff algorithms for gutter markers and the side-by-side `DiffWindowController`.

## Packaging notes

- `bundle.sh` must copy SwiftPM `*.bundle` resources into `Contents/Resources` — tree-sitter queries are loaded from there.
- `release.sh` assembles the release app in a temp copy so `build/MayloveE.app` stays a dev build; the jlinked JRE goes in `Contents/Resources/jre` (not `PlugIns`, which codesign treats as code). jdtls version/build/sha256 and the jlink module list are pinned at the top of the script; the app version comes from `Support/Info.plist`.
- `Support/AppIcon.icns` is generated by `scripts/make-icon.swift`. Third-party licenses for bundled components go in `THIRD_PARTY_NOTICES.md`.
