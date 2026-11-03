import Foundation
import Testing
@testable import MayloveE

struct UTF8StreamDecoderTests {
    @Test func reassemblesCharactersSplitAcrossChunks() {
        let text = "Pending: 任务 ✓ 😀 done"
        let bytes = Array(text.utf8)
        // Every split point, including inside 2-, 3- and 4-byte characters.
        for split in 0...bytes.count {
            var decoder = UTF8StreamDecoder()
            let output = decoder.decode(Data(bytes[..<split])) + decoder.decode(Data(bytes[split...]))
            #expect(output == text, "split at \(split)")
        }
    }
}

struct ConsoleLinkTests {
    @Test func detectsMavenCompilerError() {
        let line = "[ERROR] /Users/me/demo/src/main/java/demo/App.java:[12,9] cannot find symbol"
        let links = ConsoleLinkDetector.links(in: line)
        #expect(links.map(\.link) == [.file(path: "/Users/me/demo/src/main/java/demo/App.java", line: 12, column: 9)])
        #expect((line as NSString).substring(with: links[0].range) == "/Users/me/demo/src/main/java/demo/App.java:[12,9]")
    }

    @Test func detectsJavacError() {
        let links = ConsoleLinkDetector.links(in: "/tmp/demo/App.java:7: error: ';' expected")
        #expect(links.map(\.link) == [.file(path: "/tmp/demo/App.java", line: 7, column: 1)])
    }

    @Test func detectsStackFrameAndLinksFileAndLine() {
        let line = "\tat com.example.demo.service.TaskService$Inner.lambda$pending$0(TaskService.java:37)"
        let links = ConsoleLinkDetector.links(in: line)
        #expect(links.map(\.link) == [.stackFrame(className: "com.example.demo.service.TaskService$Inner",
                                                   fileName: "TaskService.java", line: 37)])
        #expect((line as NSString).substring(with: links[0].range) == "TaskService.java:37")
    }

    @Test func ignoresFramesWithoutSource() {
        #expect(ConsoleLinkDetector.links(in: "\tat java.lang.Thread.run(Native Method)").isEmpty)
        #expect(ConsoleLinkDetector.links(in: "Tests run: 5, Failures: 0").isEmpty)
    }

    @Test func linksRoundTripThroughURL() throws {
        for link in [ConsoleLink.file(path: "/a b/C.java", line: 3, column: 4),
                     .stackFrame(className: "a.B$C", fileName: "B.java", line: 9)] {
            #expect(ConsoleLink(url: try #require(link.url)) == link)
        }
    }

    @Test func locatesSourcesInModules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Locator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("core/src/test/java/a/b/FooTest.java")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: source, atomically: true, encoding: .utf8)
        try "<project/>".write(to: root.appendingPathComponent("core/pom.xml"), atomically: true, encoding: .utf8)

        let locator = SourceLocator(projectRoot: root)
        #expect(locator.file(forClass: "a.b.FooTest$Nested", fileName: "FooTest.java")?.standardizedFileURL
                == source.standardizedFileURL)
        #expect(locator.file(forClass: "a.b.Missing", fileName: "Missing.java") == nil)

        #expect(try BuildTools.mavenModule(containing: source, root: root).standardizedFileURL.path
                == root.appendingPathComponent("core").standardizedFileURL.path)
    }
}
