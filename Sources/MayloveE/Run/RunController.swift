import AppKit
import os

/// Runs main classes (directly with the project JDK and jdtls's classpath) and tests (via Maven
/// Surefire), streaming output into the console.
@MainActor
final class RunController {
    private static let logger = Logger(subsystem: "MayloveE", category: "Run")

    private struct Request {
        let target: RunTarget
        /// The file the run was started from; identifies the project/module.
        let file: URL
    }

    let console = ConsoleViewController()
    var onShowConsole: (() -> Void)?
    var onHideConsole: (() -> Void)?
    var onOpenLocation: ((LSPLocation) -> Void)?
    /// Saves modified editors before building; returns false if saving failed.
    var saveAll: (() -> Bool)?

    private let rootURL: URL
    private let languageServer: () -> JavaLanguageServer
    private var session: RunSession?
    private var lastRequest: Request?
    /// Bumped per run so a superseded run that is still preparing never starts.
    private var generation = 0

    init(rootURL: URL, languageServer: @escaping () -> JavaLanguageServer) {
        self.rootURL = rootURL
        self.languageServer = languageServer
        console.onRerun = { [weak self] in self?.rerun() }
        console.onStop = { [weak self] in self?.stop() }
        console.onClose = { [weak self] in self?.onHideConsole?() }
        console.onOpenLink = { [weak self] link in self?.open(link) }
    }

    var isRunning: Bool { session?.isRunning == true }

    func run(_ target: RunTarget, from file: URL) {
        stop()
        guard saveAll?() != false else { return }
        let request = Request(target: target, file: file)
        lastRequest = request
        generation += 1
        let runGeneration = generation
        console.begin(title: target.title)
        onShowConsole?()
        Task { await execute(request, generation: runGeneration) }
    }

    func rerun() {
        guard let lastRequest else {
            NSSound.beep()
            return
        }
        run(lastRequest.target, from: lastRequest.file)
    }

    func stop() {
        session?.stop()
    }

    private func execute(_ request: Request, generation runGeneration: Int) async {
        do {
            let prepared: RunSession?
            switch request.target {
            case .mainClass(let className):
                prepared = try await prepareMain(className, file: request.file)
            case .testClass, .testMethod:
                prepared = try await prepareTests(request.target, file: request.file)
            }
            guard runGeneration == generation else { return }
            guard let prepared else {
                console.setRunning(false)
                return
            }
            start(prepared, target: request.target)
        } catch {
            guard runGeneration == generation else { return }
            Self.logger.error("Run failed: \(error.localizedDescription, privacy: .public)")
            console.appendSystem("\(error.localizedDescription)\n")
            console.setRunning(false)
        }
    }

    /// Returns nil (after printing the errors) if the project does not compile.
    private func prepareMain(_ className: String, file: URL) async throws -> RunSession? {
        let server = languageServer()
        if server.status != .ready {
            console.appendSystem("Waiting for the Java language server to import the project…\n")
        }
        try await server.waitUntilReady()

        let build = try await server.build()
        if build != .succeeded {
            // jdtls publishes the diagnostics of a build shortly after answering the build request.
            let deadline = ContinuousClock.now + .seconds(3)
            while server.allErrors().isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let errors = server.allErrors()
            guard !errors.isEmpty else {
                console.appendSystem("Build failed (\(build)); the language server has not reported the errors yet.\n")
                return nil
            }
            console.appendSystem("Build failed with \(errors.count) error(s):\n")
            for (url, diagnostic) in errors {
                let start = diagnostic.range.start
                // Same shape as Maven's errors, so the console links them.
                console.append("[ERROR] \(url.path):[\(start.line + 1),\(start.character + 1)] \(diagnostic.message)\n",
                               stream: .stderr)
            }
            return nil
        }

        let scope = file.path.contains("/src/test/") ? "test" : "runtime"
        let classpath = try await server.classpath(for: file, scope: scope)
        guard let jdk = try await server.projectJDK(for: file) else {
            throw RunError.noJDK
        }
        let module = (try? BuildTools.mavenModule(containing: file, root: rootURL)) ?? rootURL
        return RunSession(executable: jdk.appendingPathComponent("bin/java"),
                          arguments: ["-Dfile.encoding=UTF-8", "-cp", classpath.joined(separator: ":"), className],
                          directory: module,
                          environment: BuildTools.processEnvironment(javaHome: jdk))
    }

    private func prepareTests(_ target: RunTarget, file: URL) async throws -> RunSession {
        let module = try BuildTools.mavenModule(containing: file, root: rootURL)
        // Run Maven on the project's JDK when jdtls already knows it; otherwise use the shell's JAVA_HOME.
        let server = languageServer()
        var jdk: URL?
        if server.status == .ready {
            jdk = try? await server.projectJDK(for: file)
        }
        let environment = BuildTools.processEnvironment(javaHome: jdk)
        let maven = try BuildTools.maven(for: module, root: rootURL, environment: environment)
        return RunSession(executable: maven,
                          arguments: ["-B", "test", "-Dtest=\(Self.surefireSelector(for: target))",
                                      "-DfailIfNoTests=false", "-Dsurefire.failIfNoSpecifiedTests=false"],
                          directory: module,
                          environment: environment)
    }

    private func start(_ session: RunSession, target: RunTarget) {
        session.onOutput = { [weak self] text, stream in self?.console.append(text, stream: stream) }
        session.onExit = { [weak self, weak session] status in
            guard let self, let session, self.session === session else { return }
            self.finish(target: target, status: status)
        }
        console.appendSystem(session.commandLine + "\n")
        do {
            try session.start()
            self.session = session
        } catch {
            console.appendSystem("Cannot start: \(error.localizedDescription)\n")
            console.setRunning(false)
        }
    }

    private func finish(target: RunTarget, status: Int32) {
        console.appendSystem("\nProcess finished with exit code \(status)\n")
        console.setRunning(false)
        if case .mainClass = target { return }
        if let summary = TestSummary.last(in: console.text) {
            console.setTitle("\(target.title) — \(summary.description)")
        }
    }

    private func open(_ link: ConsoleLink) {
        switch link {
        case .file(let path, let line, let column):
            onOpenLocation?(Self.location(URL(fileURLWithPath: path), line: line, column: column))
        case .stackFrame(let className, let fileName, let line):
            guard let file = SourceLocator(projectRoot: rootURL).file(forClass: className, fileName: fileName) else {
                NSSound.beep()
                return
            }
            onOpenLocation?(Self.location(file, line: line, column: 1))
        }
    }

    private static func location(_ url: URL, line: Int, column: Int) -> LSPLocation {
        let position = LSPPosition(line: max(line - 1, 0), character: max(column - 1, 0))
        return LSPLocation(url: url, range: LSPRange(start: position, end: position))
    }

    /// Surefire's -Dtest syntax: `Class` or `Class#method`, by simple class name.
    nonisolated static func surefireSelector(for target: RunTarget) -> String {
        let simpleName = target.className.components(separatedBy: ".").last ?? target.className
        if case .testMethod(_, let method) = target {
            return "\(simpleName)#\(method)"
        }
        return simpleName
    }

    enum RunError: LocalizedError {
        case noJDK

        var errorDescription: String? {
            "The Java language server reported no JDK for this project."
        }
    }
}

/// The totals line Surefire prints at the end of a run.
struct TestSummary: Equatable {
    let run: Int
    let failures: Int
    let errors: Int
    let skipped: Int

    private static let pattern = try! NSRegularExpression(
        pattern: #"^\[(?:INFO|WARNING|ERROR)\] Tests run: (\d+), Failures: (\d+), Errors: (\d+), Skipped: (\d+)\s*$"#,
        options: .anchorsMatchLines)

    /// The last totals line; per-class lines also carry "Time elapsed" and are not matched.
    static func last(in output: String) -> TestSummary? {
        let text = output as NSString
        guard let match = pattern.matches(in: output, range: NSRange(location: 0, length: text.length)).last else {
            return nil
        }
        let number = { (index: Int) in Int(text.substring(with: match.range(at: index))) ?? 0 }
        return TestSummary(run: number(1), failures: number(2), errors: number(3), skipped: number(4))
    }

    var description: String {
        let failed = failures + errors
        return failed == 0 ? "\(run - skipped) passed" : "\(failed) of \(run) failed"
    }
}
