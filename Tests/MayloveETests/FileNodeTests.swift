import Foundation
import Testing
@testable import MayloveE

@MainActor
struct FileNodeTests {
    @Test func compactsSingleChildPackagesOnlyInJavaSourceRoots() throws {
        let root = try TestJavaProject.make(files: [
            "src/main/java/com/example/demo/App.java": "",
            "src/main/java/com/example/demo/model/Task.java": "",
            "docs/a/b/notes.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = FileNode(url: root, isDirectory: true)

        let javaRoot = try #require(child("src", of: project).flatMap { child("main", of: $0) }.flatMap { child("java", of: $0) })
        let package = try #require(javaRoot.children.first)
        #expect(package.name == "com.example.demo")
        #expect(package.url.lastPathComponent == "demo")
        // "model" sits next to App.java, so it is not merged into its parent.
        #expect(package.children.map(\.name) == ["model", "App.java"])

        let docs = try #require(child("docs", of: project))
        #expect(docs.children.map(\.name) == ["a"])
    }

    @Test func dimsHiddenFilesAndBuildOutput() {
        let root = URL(fileURLWithPath: "/tmp/project")
        #expect(FileNode(url: root.appendingPathComponent(".gitignore"), isDirectory: false).isDimmed)
        #expect(FileNode(url: root.appendingPathComponent("target"), isDirectory: true).isDimmed)
        #expect(!FileNode(url: root.appendingPathComponent("target"), isDirectory: false).isDimmed)
        #expect(!FileNode(url: root.appendingPathComponent("src"), isDirectory: true).isDimmed)
    }

    private func child(_ name: String, of node: FileNode) -> FileNode? {
        node.children.first { $0.name == name }
    }
}
