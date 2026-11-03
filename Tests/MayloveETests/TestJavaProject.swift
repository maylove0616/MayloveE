import Foundation
import Testing

/// A throwaway Maven project for language-server tests.
enum TestJavaProject {
    static func make(appSource: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MayloveE-LSP-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let sources = root.appendingPathComponent("src/main/java/demo")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        <project xmlns="http://maven.apache.org/POM/4.0.0">
            <modelVersion>4.0.0</modelVersion>
            <groupId>demo</groupId>
            <artifactId>lsp-test</artifactId>
            <version>1</version>
            <properties>
                <maven.compiler.source>1.8</maven.compiler.source>
                <maven.compiler.target>1.8</maven.compiler.target>
            </properties>
        </project>
        """.write(to: root.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
        try """
        package demo;

        /** Builds greetings. */
        public class Greeter {
            public String greet(String name) {
                return "Hello, " + name;
            }
        }
        """.write(to: sources.appendingPathComponent("Greeter.java"), atomically: true, encoding: .utf8)
        try appSource.write(to: sources.appendingPathComponent("App.java"), atomically: true, encoding: .utf8)
        return root
    }

    /// A Maven project with JUnit 4 and the given sources, keyed by path relative to the root.
    static func make(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MayloveE-Run-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        <project xmlns="http://maven.apache.org/POM/4.0.0">
            <modelVersion>4.0.0</modelVersion>
            <groupId>demo</groupId>
            <artifactId>run-test</artifactId>
            <version>1</version>
            <properties>
                <maven.compiler.source>1.8</maven.compiler.source>
                <maven.compiler.target>1.8</maven.compiler.target>
                <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
            </properties>
            <dependencies>
                <dependency>
                    <groupId>junit</groupId>
                    <artifactId>junit</artifactId>
                    <version>4.13.2</version>
                    <scope>test</scope>
                </dependency>
            </dependencies>
        </project>
        """.write(to: root.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @MainActor
    static func waitUntil(timeout: Duration = .seconds(120), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for condition")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
