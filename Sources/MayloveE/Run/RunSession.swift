import Foundation
import os

/// One running child process (a program or a Maven build) with streamed output.
@MainActor
final class RunSession {
    enum Stream: Sendable {
        case stdout
        case stderr
    }

    var onOutput: ((String, Stream) -> Void)?
    var onExit: ((Int32) -> Void)?

    let commandLine: String
    private let process = Process()

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        commandLine = ([executable.path] + arguments).joined(separator: " ")
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        forward(stdout, as: .stdout)
        forward(stderr, as: .stderr)
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            // Queued after any pending output blocks, so the exit line comes last.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onExit?(status) }
            }
        }
        try process.run()
    }

    /// SIGTERM first, like IntelliJ's Stop; SIGKILL if the process ignores it.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.process.isRunning == true {
                kill(pid, SIGKILL)
            }
        }
    }

    private func forward(_ pipe: Pipe, as stream: Stream) {
        let decoder = OSAllocatedUnfairLock(initialState: UTF8StreamDecoder())
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = decoder.withLock { $0.decode(data) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onOutput?(text, stream) }
            }
        }
    }
}
