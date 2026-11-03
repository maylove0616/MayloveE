import CryptoKit
import Foundation
import os

/// One jdtls process per workspace window.
@MainActor
final class JavaLanguageServer {
    enum Status: Equatable {
        case starting(String)
        case ready
        case failed(String)
        case stopped
    }

    nonisolated private static let logger = Logger(subsystem: "MayloveE", category: "jdtls")

    let rootURL: URL
    var onStatusChange: ((Status) -> Void)?
    var onDiagnostics: ((URL, [LSPDiagnostic]) -> Void)?

    private(set) var status: Status = .stopped {
        didSet {
            if status != oldValue { onStatusChange?(status) }
        }
    }

    private var process: Process?
    private var connection: JSONRPCConnection?
    private var settings: JSONValue = .null
    private var isInitialized = false
    /// Notifications sent before `initialize` completed, replayed in order afterwards.
    private var queuedNotifications: [(String, JSONValue)] = []
    private var diagnostics: [String: [LSPDiagnostic]] = [:]

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil, case .stopped = status else { return }
        status = .starting("Starting Java language server…")
        Task {
            do {
                let toolchain = try await Task.detached { try JavaToolchain.locate() }.value
                try launch(with: toolchain)
            } catch {
                Self.logger.error("Cannot start jdtls: \(error.localizedDescription, privacy: .public)")
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Graceful shutdown; kills the process if it does not exit within a few seconds.
    func stop() {
        guard let process, let connection else { return }
        Task {
            _ = try? await connection.request("shutdown", .null)
            connection.notify("exit", .null)
            try? await Task.sleep(for: .seconds(3))
            if process.isRunning { process.terminate() }
        }
    }

    /// For app termination, where there is no time for the shutdown handshake.
    func terminate() {
        process?.terminate()
    }

    private func launch(with toolchain: JavaToolchain) throws {
        let java = toolchain.serverJavaHome.appendingPathComponent("bin/java")
        let process = Process()
        process.executableURL = java
        process.arguments = Self.jvmArguments(for: toolchain) + [
            "-jar", toolchain.launcherJar.path,
            "-data", try Self.workspaceDataDirectory(for: rootURL).path,
        ]
        process.currentDirectoryURL = rootURL

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // jdtls logs to stderr; it must be drained or the process blocks once the pipe fills.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                Self.logger.debug("\(String(decoding: data, as: UTF8.self), privacy: .public)")
            }
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.processDidExit(code: code) }
            }
        }

        let connection = JSONRPCConnection(readingFrom: stdout.fileHandleForReading,
                                           writingTo: stdin.fileHandleForWriting)
        connection.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
        connection.onRequest = { [weak self] method, params in self?.handleRequest(method, params) ?? .null }

        try process.run()
        self.process = process
        self.connection = connection
        settings = Self.settings(for: toolchain)

        Task { await initialize() }
    }

    private static func jvmArguments(for toolchain: JavaToolchain) -> [String] {
        var arguments = [
            "-Declipse.application=org.eclipse.jdt.ls.core.id1",
            "-Dosgi.bundles.defaultStartLevel=4",
            "-Declipse.product=org.eclipse.jdt.ls.core.product",
            "-Dosgi.checkConfiguration=true",
            "-Dosgi.sharedConfiguration.area=" + toolchain.jdtlsHome.appendingPathComponent("config_mac_arm").path,
            "-Dosgi.sharedConfiguration.area.readOnly=true",
            "-Dosgi.configuration.cascaded=true",
            "-Xmx2G",
            "--add-modules=ALL-SYSTEM",
            "--add-opens", "java.base/java.util=ALL-UNNAMED",
            "--add-opens", "java.base/java.lang=ALL-UNNAMED",
        ]
        // Mirrors jdtls's own launcher script for JDK 24+.
        if toolchain.serverJavaMajorVersion >= 24 {
            arguments.insert(contentsOf: ["-Djdk.xml.maxGeneralEntitySizeLimit=0",
                                          "-Djdk.xml.totalEntitySizeLimit=0"], at: 0)
        }
        return arguments
    }

    /// jdtls keeps per-project indexes here; one directory per workspace root.
    private static func workspaceDataDirectory(for rootURL: URL) throws -> URL {
        let digest = SHA256.hash(data: Data(rootURL.standardizedFileURL.path.utf8))
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let directory = caches.appendingPathComponent("MayloveE/jdtls-workspaces/\(rootURL.lastPathComponent)-\(suffix)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func settings(for toolchain: JavaToolchain) -> JSONValue {
        let runtimes = toolchain.runtimes.enumerated().map { index, runtime -> JSONValue in
            ["name": .string(runtime.name), "path": .string(runtime.home.path), "default": .bool(index == 0)]
        }
        return ["java": ["configuration": ["runtimes": .array(runtimes)]]]
    }

    private func initialize() async {
        guard let connection else { return }
        let rootURI = JSONValue.string(rootURL.absoluteString)
        let params: JSONValue = [
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": rootURI,
            "workspaceFolders": [["uri": rootURI, "name": .string(rootURL.lastPathComponent)]],
            "capabilities": [
                "workspace": ["configuration": true, "workspaceFolders": true],
                "textDocument": [
                    "synchronization": ["didSave": true],
                    "completion": ["completionItem": [
                        "snippetSupport": false,
                        "resolveSupport": ["properties": ["documentation", "detail", "additionalTextEdits"]],
                    ]],
                    "hover": ["contentFormat": ["plaintext", "markdown"]],
                    "definition": [:],
                    "references": [:],
                    "publishDiagnostics": [:],
                ],
            ],
            "initializationOptions": [
                "settings": settings,
                // Without this jdtls returns no locations inside the JDK or libraries.
                "extendedClientCapabilities": ["classFileContentsSupport": true],
            ],
        ]
        do {
            _ = try await connection.request("initialize", params)
            connection.notify("initialized", [:])
            isInitialized = true
            let queued = queuedNotifications
            queuedNotifications.removeAll()
            queued.forEach { connection.notify($0.0, $0.1) }
        } catch {
            Self.logger.error("jdtls initialize failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    private func processDidExit(code: Int32) {
        connection?.close()
        connection = nil
        process = nil
        isInitialized = false
        if case .failed = status { return }
        status = code == 0 ? .stopped : .failed("Java language server exited with code \(code)")
    }

    // MARK: - Server messages

    private func handleNotification(_ method: String, _ params: JSONValue) {
        switch method {
        case "textDocument/publishDiagnostics":
            guard let uri = params["uri"]?.stringValue, let url = URL(string: uri) else { return }
            let items = params["diagnostics"]?.arrayValue?.compactMap(LSPDiagnostic.init) ?? []
            diagnostics[url.standardizedFileURL.path] = items
            onDiagnostics?(url, items)
        case "language/status":
            let message = params["message"]?.stringValue ?? ""
            switch params["type"]?.stringValue {
            case "ServiceReady": status = .ready
            case "Error": status = .failed(message)
            case "Starting" where status != .ready: status = .starting(message)
            default: break
            }
        default:
            break
        }
    }

    private func handleRequest(_ method: String, _ params: JSONValue) -> JSONValue {
        switch method {
        case "workspace/configuration":
            // One result per requested section, e.g. "java".
            let items = params["items"]?.arrayValue ?? []
            return .array(items.map { item in
                item["section"]?.stringValue.flatMap { settings[$0] } ?? .null
            })
        default:
            // registerCapability, workDoneProgress/create, etc. only need an acknowledgement.
            return .null
        }
    }

    // MARK: - Documents

    func diagnostics(for url: URL) -> [LSPDiagnostic] {
        diagnostics[url.standardizedFileURL.path] ?? []
    }

    func didOpen(_ url: URL, text: String, version: Int) {
        notify("textDocument/didOpen", ["textDocument": [
            "uri": .string(url.absoluteString), "languageId": "java",
            "version": .number(Double(version)), "text": .string(text),
        ]])
    }

    func didChange(_ url: URL, text: String, version: Int) {
        notify("textDocument/didChange", [
            "textDocument": ["uri": .string(url.absoluteString), "version": .number(Double(version))],
            "contentChanges": [["text": .string(text)]],
        ])
    }

    func didSave(_ url: URL) {
        notify("textDocument/didSave", ["textDocument": ["uri": .string(url.absoluteString)]])
    }

    func didClose(_ url: URL) {
        notify("textDocument/didClose", ["textDocument": ["uri": .string(url.absoluteString)]])
    }

    private func notify(_ method: String, _ params: JSONValue) {
        if isInitialized {
            connection?.notify(method, params)
        } else {
            queuedNotifications.append((method, params))
        }
    }

    // MARK: - Features

    func completion(_ url: URL, at position: LSPPosition) async throws -> [LSPCompletionItem] {
        LSPCompletionItem.list(from: try await request("textDocument/completion", positionParams(url, position)))
    }

    func resolve(_ item: LSPCompletionItem) async throws -> LSPCompletionItem {
        LSPCompletionItem(try await request("completionItem/resolve", item.raw)) ?? item
    }

    func definition(_ url: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        LSPLocation.list(from: try await request("textDocument/definition", positionParams(url, position)))
    }

    func references(_ url: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        var params = positionParams(url, position)
        if case .object(var object) = params {
            object["context"] = ["includeDeclaration": false]
            params = .object(object)
        }
        return LSPLocation.list(from: try await request("textDocument/references", params))
    }

    func hover(_ url: URL, at position: LSPPosition) async throws -> [HoverPart] {
        LSPHover.parts(from: try await request("textDocument/hover", positionParams(url, position)))
    }

    /// Source (attached or decompiled) for a `jdt://` location inside the JDK or a library.
    func classFileContents(_ url: URL) async throws -> String? {
        try await request("java/classFileContents", ["uri": .string(url.absoluteString)]).stringValue
    }

    private func positionParams(_ url: URL, _ position: LSPPosition) -> JSONValue {
        ["textDocument": ["uri": .string(url.absoluteString)], "position": position.json]
    }

    private func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard isInitialized, let connection else { throw JSONRPCError.connectionClosed }
        return try await connection.request(method, params)
    }
}
