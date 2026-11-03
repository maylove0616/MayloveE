import Foundation
import Testing
@testable import MayloveE

@MainActor
struct FileWatcherTests {
    @Test func reportsChangesAndSurvivesReleaseWhileEventsArePending() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MayloveE-Watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var changes = 0
        let watcher = FileWatcher(urls: [directory], latency: 0.05) { _ in changes += 1 }
        try "a".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await TestJavaProject.waitUntil(timeout: .seconds(10)) { changes > 0 }
        withExtendedLifetime(watcher) {}

        // Regression: a watcher released without stop() left FSEvents calling into freed memory.
        var released: FileWatcher? = FileWatcher(urls: [directory], latency: 0.05) { _ in }
        try "b".write(to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        released = nil
        try "c".write(to: directory.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))
        #expect(released == nil)
    }
}
