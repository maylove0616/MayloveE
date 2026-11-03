# MayloveE

A lightweight, native macOS IDE for Java, written in Swift and AppKit.

MayloveE aims to cover the everyday Java workflow — edit, navigate, run, test, commit — without the
weight of a full JVM-based IDE. Language intelligence comes from
[Eclipse JDT Language Server](https://github.com/eclipse-jdtls/eclipse.jdt.ls) (jdtls), syntax
highlighting from [tree-sitter](https://tree-sitter.github.io/), and Git from the `git` command line.
Keyboard shortcuts follow IntelliJ IDEA's macOS keymap.

## Features

- **Editor** — line numbers, auto-indent, tree-sitter syntax highlighting with light and dark
  colors, adjustable font size.
- **Code intelligence** (via jdtls) — errors and warnings as you type, code completion with
  auto-import, go to declaration (including JDK and library sources), find usages, quick
  documentation on hover.
- **Run and test** — run the `main` class or the test method/class at the caret; tests run through
  Maven Surefire (the project's `mvnw` if present). Output goes to a console with clickable
  compiler errors and stack-trace lines.
- **Git** — status colors in the file tree and tabs, change markers in the gutter, a Commit tool
  window (select files, commit, commit and push, amend, rollback), side-by-side diffs, branch
  switching and creation, pull, push, fetch, and a log panel.
- **Workspace** — file tree with compact Java packages, tabs, and automatic refresh when files
  change outside the IDE.

## Requirements

- macOS 14 or later (developed on Apple Silicon).
- A Swift 6 toolchain: Xcode, or just the Command Line Tools (`xcode-select --install`).
- **jdtls 1.63** and a **JDK 25 or newer** to run it (jdtls requires Java 25). Your projects can
  still target older Java versions — see [JDKs](#jdks).
- Maven, if the project has no `mvnw`, for running tests.

## Installing jdtls

MayloveE looks for jdtls in `~/Library/Application Support/MayloveE/jdtls/<version>/` and uses the
newest version found there.

```bash
mkdir -p ~/Library/Application\ Support/MayloveE/jdtls/1.63.0
```

```bash
curl -L https://download.eclipse.org/jdtls/milestones/1.63.0/jdt-language-server-1.63.0-202610191322.tar.gz | tar -xz -C ~/Library/Application\ Support/MayloveE/jdtls/1.63.0
```

Then install a JDK 25+ to run it, for example:

```bash
brew install openjdk
```

## Building

```bash
scripts/bundle.sh
```

This builds a release binary and wraps it into `build/MayloveE.app` (ad-hoc signed). Open a project
folder with:

```bash
open build/MayloveE.app --args /path/to/your/java-project
```

Without an argument, MayloveE asks for a folder.

## JDKs

jdtls itself runs on the JDK 25+ described above. For your code, MayloveE registers every JDK known
to `/usr/libexec/java_home` with jdtls, which picks the one matching the project's Java version
(for example `maven.compiler.source` 1.8 → a Java 8 JDK). Programs and tests run on that project JDK.

## Configuration

| Environment variable | Purpose |
|---|---|
| `MAYLOVEE_JDTLS_HOME` | Use a jdtls installation from another directory. |
| `MAYLOVEE_JDTLS_JAVA_HOME` | JDK used to run jdtls (must be 25+). |
| `MAYLOVEE_MAVEN` | Maven executable, when the project has no `mvnw` and `mvn` is not on `PATH`. |
| `MAYLOVEE_GIT` | Git executable (default `/usr/bin/git`). |

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Complete code | ⌃Space |
| Go to declaration | ⌘B or ⌘-click |
| Find usages | ⌥F7 |
| Quick documentation | F1 |
| Run context configuration | ⌃⇧R |
| Rerun / Stop | ⌃R / ⌘F2 |
| Show/hide console | ⌘4 |
| Project / Commit tool window | ⌘1 / ⌘0 |
| Commit | ⌘K |
| Push | ⇧⌘K |
| Update project (pull) | ⌘T |
| Git log | ⌘9 |
| Rollback current file | ⌥⌘Z |
| Next / previous difference (diff window) | F7 / ⇧F7 |
| Increase / decrease / reset font size | ⌘= / ⌘- / ⌥⌘0 |
| Next / previous tab | ⇧⌘] / ⇧⌘[ |

## Running the tests

```bash
swift test
```

With only the Command Line Tools installed (no Xcode), point the compiler at the Swift Testing macro
plugin:

```bash
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

Tests that start jdtls or Maven are skipped when jdtls is not installed.

## Current limitations

- No debugger yet.
- Running programs cannot read from standard input, and there are no run configurations
  (program arguments, environment variables).
- Test results appear in the console only; there is no test tree.
- Tests run through Maven only; multi-module Maven projects have basic support, and Gradle
  projects are untested.
- Git: merge conflicts are marked but must be resolved elsewhere; no per-hunk rollback; the log
  shows the current branch without a graph.

## License

[MIT](LICENSE)
