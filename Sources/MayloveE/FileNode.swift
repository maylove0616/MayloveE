import Foundation
import os

@MainActor
final class FileNode {
    private static let ignoredNames: Set<String> = [".git", ".idea", ".DS_Store"]
    private static let logger = Logger(subsystem: "MayloveE", category: "FileNode")

    let url: URL
    let isDirectory: Bool

    private(set) lazy var children: [FileNode] = isDirectory ? loadChildren() : []

    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    private func loadChildren() -> [FileNode] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: url,
                                                               includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            Self.logger.error("Cannot list \(self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }

        return urls
            .filter { !Self.ignoredNames.contains($0.lastPathComponent) }
            .map { childURL in
                let isDirectory = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FileNode(url: childURL, isDirectory: isDirectory)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
