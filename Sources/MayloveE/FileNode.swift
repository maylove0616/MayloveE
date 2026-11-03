import Foundation
import os

@MainActor
final class FileNode {
    private static let ignoredNames: Set<String> = [".git", ".idea", ".DS_Store"]
    private static let buildOutputNames: Set<String> = ["target", "build", "out"]
    private static let logger = Logger(subsystem: "MayloveE", category: "FileNode")

    let url: URL
    let isDirectory: Bool
    /// The file name, or a compacted package such as "com.example.demo".
    let name: String

    private(set) lazy var children: [FileNode] = isDirectory ? loadChildren() : []

    /// Hidden files and build output, shown dimmed.
    var isDimmed: Bool {
        url.lastPathComponent.hasPrefix(".") || (isDirectory && Self.buildOutputNames.contains(url.lastPathComponent))
    }

    init(url: URL, isDirectory: Bool, name: String? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.name = name ?? url.lastPathComponent
    }

    private func loadChildren() -> [FileNode] {
        let inSourceRoot = Self.isJavaSourceRoot(url) || Self.isInJavaSourceRoot(url)
        return Self.visibleChildren(of: url)
            .map { childURL, isDirectory in
                guard isDirectory, inSourceRoot else {
                    return FileNode(url: childURL, isDirectory: isDirectory)
                }
                return Self.compactPackage(startingAt: childURL)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Like IntelliJ IDEA's compact middle packages: a package whose only entry is a
    /// subpackage is shown merged with it, e.g. "com.example.demo".
    private static func compactPackage(startingAt url: URL) -> FileNode {
        var current = url
        var names = [url.lastPathComponent]
        while true {
            let entries = visibleChildren(of: current)
            guard entries.count == 1, entries[0].isDirectory else { break }
            current = entries[0].url
            names.append(current.lastPathComponent)
        }
        return FileNode(url: current, isDirectory: true, name: names.joined(separator: "."))
    }

    private static func visibleChildren(of url: URL) -> [(url: URL, isDirectory: Bool)] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: url,
                                                               includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            logger.error("Cannot list \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
        return urls
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .map { childURL in
                (childURL, (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
            }
    }

    /// Maven/Gradle layout: src/<set>/java.
    private static func isJavaSourceRoot(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return components.count >= 3 && components[components.count - 1] == "java"
            && components[components.count - 3] == "src"
    }

    private static func isInJavaSourceRoot(_ url: URL) -> Bool {
        var ancestor = url.standardizedFileURL.deletingLastPathComponent()
        while ancestor.pathComponents.count > 1 {
            if isJavaSourceRoot(ancestor) { return true }
            ancestor = ancestor.deletingLastPathComponent()
        }
        return false
    }
}
