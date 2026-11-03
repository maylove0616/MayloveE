import Foundation

/// Locates Maven and builds the environment for child processes.
enum BuildTools {
    enum LocateError: LocalizedError {
        case mavenNotFound
        case noPom(URL)

        var errorDescription: String? {
            switch self {
            case .mavenNotFound:
                return "Maven not found. Add mvnw to the project, install Maven, or set MAYLOVEE_MAVEN."
            case .noPom(let file):
                return "No pom.xml found above \(file.path)."
            }
        }
    }

    /// The directory of the nearest pom.xml at or above `file`, but not above `root`.
    static func mavenModule(containing file: URL, root: URL) throws -> URL {
        let rootPath = root.standardizedFileURL.path
        var directory = file.standardizedFileURL.deletingLastPathComponent()
        while directory.path.hasPrefix(rootPath) {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("pom.xml").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw LocateError.noPom(file)
    }

    /// Prefers the project's Maven wrapper, as IntelliJ does.
    static func maven(for module: URL, root: URL, environment: [String: String]) throws -> URL {
        for directory in [module, root] {
            let wrapper = directory.appendingPathComponent("mvnw")
            if FileManager.default.isExecutableFile(atPath: wrapper.path) {
                return wrapper
            }
        }
        if let configured = environment["MAYLOVEE_MAVEN"] {
            return URL(fileURLWithPath: configured)
        }
        let searchPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in searchPath + ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("mvn")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw LocateError.mavenNotFound
    }

    /// Apps started from Finder get a minimal PATH; borrow the one from the user's login shell.
    static func processEnvironment(javaHome: URL?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let path = loginShellPath {
            environment["PATH"] = path
        }
        if let javaHome {
            environment["JAVA_HOME"] = javaHome.path
            environment["PATH"] = javaHome.appendingPathComponent("bin").path + ":" + (environment["PATH"] ?? "")
        }
        // Without a UTF-8 locale, Java 8 prints non-ASCII output as "?".
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        return environment
    }

    private static let loginShellPath: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf '%s' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Login scripts may print banners; PATH is the last line.
        let path = String(decoding: data, as: UTF8.self).components(separatedBy: "\n").last ?? ""
        return process.terminationStatus == 0 && path.contains("/") ? path : nil
    }()
}
