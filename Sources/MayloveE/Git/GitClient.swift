import Foundation
import os

/// Runs the git command line in a repository, off the main thread.
struct GitClient: Sendable {
    struct Failure: LocalizedError {
        let arguments: [String]
        let status: Int32
        let output: String

        var errorDescription: String? {
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "git \(arguments.first ?? "") failed with exit code \(status)" : message
        }
    }

    let directory: URL

    /// Overridable for a git other than the one from the Command Line Tools.
    static var executable: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAYLOVEE_GIT"] ?? "/usr/bin/git")
    }

    /// The login shell's PATH reaches credential helpers such as `gh`; git must never wait for a
    /// terminal prompt, and read-only commands must not take the index lock.
    private static let environment: [String: String] = {
        var environment = BuildTools.processEnvironment(javaHome: nil)
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "en_US.UTF-8"
        return environment
    }()

    func output(_ arguments: [String]) async throws -> String {
        String(decoding: try await run(arguments), as: UTF8.self)
    }

    /// Stdout of a successful command; stderr (or stdout) of a failed one becomes the error.
    func run(_ arguments: [String]) async throws -> Data {
        let directory = self.directory
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.runBlocking(arguments, in: directory) })
            }
        }
    }

    private static func runBlocking(_ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Drain stderr concurrently so neither pipe fills up and blocks git.
        let errorOutput = OSAllocatedUnfairLock(initialState: Data())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            errorOutput.withLock { $0 = data }
            group.leave()
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: errorOutput.withLock { $0 }, as: UTF8.self)
            let message = errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(decoding: data, as: UTF8.self) : errorText
            throw Failure(arguments: arguments, status: process.terminationStatus, output: message)
        }
        return data
    }
}
