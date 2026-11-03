import Foundation

/// Locates the JDK that runs jdtls, the jdtls installation, and the JDKs projects compile against.
struct JavaToolchain: Sendable {
    struct Runtime: Sendable {
        let name: String
        let home: URL
    }

    /// jdtls 1.63 requires Java 25 or newer to run.
    static let minimumServerJavaVersion = 25

    let serverJavaHome: URL
    let serverJavaMajorVersion: Int
    let jdtlsHome: URL
    let launcherJar: URL
    let runtimes: [Runtime]

    enum LocateError: LocalizedError {
        case serverJavaNotFound
        case jdtlsNotFound(URL)

        var errorDescription: String? {
            switch self {
            case .serverJavaNotFound:
                return "No JDK \(JavaToolchain.minimumServerJavaVersion)+ found for jdtls. "
                    + "Set MAYLOVEE_JDTLS_JAVA_HOME or install one (e.g. `brew install openjdk`)."
            case .jdtlsNotFound(let directory):
                return "jdtls not found in \(directory.path). Set MAYLOVEE_JDTLS_HOME."
            }
        }
    }

    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> JavaToolchain {
        guard let (javaHome, javaVersion) = serverJavaCandidates(environment: environment)
            .lazy
            .compactMap({ home in majorVersion(ofJavaHome: home).map { (home, $0) } })
            .first(where: { $0.1 >= minimumServerJavaVersion }) else {
            throw LocateError.serverJavaNotFound
        }

        let jdtlsHome = try locateJdtls(environment: environment)
        let plugins = jdtlsHome.appendingPathComponent("plugins")
        let launcher = (try? FileManager.default.contentsOfDirectory(atPath: plugins.path))?
            .first { $0.hasPrefix("org.eclipse.equinox.launcher_") && $0.hasSuffix(".jar") }
        guard let launcher else { throw LocateError.jdtlsNotFound(jdtlsHome) }

        return JavaToolchain(serverJavaHome: javaHome,
                             serverJavaMajorVersion: javaVersion,
                             jdtlsHome: jdtlsHome,
                             launcherJar: plugins.appendingPathComponent(launcher),
                             runtimes: installedRuntimes())
    }

    private static func serverJavaCandidates(environment: [String: String]) -> [URL] {
        var candidates: [URL] = []
        if let home = environment["MAYLOVEE_JDTLS_JAVA_HOME"] {
            candidates.append(URL(fileURLWithPath: home))
        }
        if let home = javaHome(version: "\(minimumServerJavaVersion)+") {
            candidates.append(home)
        }
        // Homebrew's openjdk formula is keg-only, so java_home does not list it.
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home"))
        return candidates
    }

    private static func locateJdtls(environment: [String: String]) throws -> URL {
        if let home = environment["MAYLOVEE_JDTLS_HOME"] {
            return URL(fileURLWithPath: home)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MayloveE/jdtls")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        let newest = versions
            .filter { FileManager.default.fileExists(atPath: base.appendingPathComponent("\($0)/plugins").path) }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
        guard let newest else { throw LocateError.jdtlsNotFound(base) }
        return base.appendingPathComponent(newest)
    }

    /// JDKs registered with macOS, exposed to jdtls as execution environments.
    private static func installedRuntimes() -> [Runtime] {
        let environments = [("JavaSE-1.8", "1.8", 8), ("JavaSE-11", "11", 11), ("JavaSE-17", "17", 17),
                            ("JavaSE-21", "21", 21), ("JavaSE-25", "25", 25)]
        return environments.compactMap { name, version, major in
            guard let home = javaHome(version: version), majorVersion(ofJavaHome: home) == major else { return nil }
            return Runtime(name: name, home: home)
        }
    }

    private static func javaHome(version: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        process.arguments = ["-v", version]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Reads JAVA_VERSION from the JDK's `release` file ("1.8.0_512" → 8, "27.0.1" → 27).
    static func majorVersion(ofJavaHome home: URL) -> Int? {
        guard let release = try? String(contentsOf: home.appendingPathComponent("release"), encoding: .utf8),
              let line = release.components(separatedBy: .newlines).first(where: { $0.hasPrefix("JAVA_VERSION=") })
        else { return nil }
        let version = line.dropFirst("JAVA_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let first = parts.first else { return nil }
        return first == 1 && parts.count > 1 ? parts[1] : first
    }
}
