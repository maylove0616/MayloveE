import Foundation
import Testing
@testable import MayloveE

struct JavaToolchainTests {
    /// A fake app with a bundled runtime (only its `release` file) and jdtls (only its launcher jar).
    private func makeApp(javaVersion: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("MayloveE-Bundle-\(UUID().uuidString).app")
        let jre = JavaToolchain.bundledJavaHome(in: app)
        let plugins = JavaToolchain.bundledJdtlsHome(in: app).appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: jre, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try "JAVA_VERSION=\"\(javaVersion)\"\n".write(to: jre.appendingPathComponent("release"),
                                                      atomically: true, encoding: .utf8)
        try Data().write(to: plugins.appendingPathComponent("org.eclipse.equinox.launcher_1.7.0.jar"))
        return app
    }

    @Test func prefersRuntimeAndJdtlsBundledInTheApp() throws {
        let app = try makeApp(javaVersion: "27.0.1")
        defer { try? FileManager.default.removeItem(at: app) }

        let toolchain = try JavaToolchain.locate(environment: [:], appBundle: app)

        #expect(toolchain.serverJavaHome == JavaToolchain.bundledJavaHome(in: app))
        #expect(toolchain.serverJavaMajorVersion == 27)
        #expect(toolchain.jdtlsHome == JavaToolchain.bundledJdtlsHome(in: app))
        #expect(toolchain.launcherJar.lastPathComponent == "org.eclipse.equinox.launcher_1.7.0.jar")
    }

    @Test func environmentOverridesTheBundle() throws {
        let app = try makeApp(javaVersion: "27.0.1")
        let other = try makeApp(javaVersion: "26")
        defer {
            try? FileManager.default.removeItem(at: app)
            try? FileManager.default.removeItem(at: other)
        }

        let toolchain = try JavaToolchain.locate(environment: [
            "MAYLOVEE_JDTLS_JAVA_HOME": JavaToolchain.bundledJavaHome(in: other).path,
            "MAYLOVEE_JDTLS_HOME": JavaToolchain.bundledJdtlsHome(in: other).path,
        ], appBundle: app)

        #expect(toolchain.serverJavaMajorVersion == 26)
        #expect(toolchain.jdtlsHome.path == JavaToolchain.bundledJdtlsHome(in: other).path)
    }
}
