import Foundation

/// Something in console output that can be opened in the editor.
enum ConsoleLink: Equatable {
    /// An absolute source path, e.g. from a javac/Maven compiler error.
    case file(path: String, line: Int, column: Int)
    /// A stack-trace frame, resolved to a source file when clicked.
    case stackFrame(className: String, fileName: String, line: Int)

    private static let scheme = "maylovee"

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .file(let path, let line, let column):
            components.host = "file"
            components.queryItems = [.init(name: "path", value: path), .init(name: "line", value: String(line)),
                                     .init(name: "column", value: String(column))]
        case .stackFrame(let className, let fileName, let line):
            components.host = "frame"
            components.queryItems = [.init(name: "class", value: className), .init(name: "file", value: fileName),
                                     .init(name: "line", value: String(line))]
        }
        return components.url
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let line = value("line").flatMap(Int.init) else { return nil }
        switch url.host {
        case "file":
            guard let path = value("path") else { return nil }
            self = .file(path: path, line: line, column: value("column").flatMap(Int.init) ?? 1)
        case "frame":
            guard let className = value("class"), let fileName = value("file") else { return nil }
            self = .stackFrame(className: className, fileName: fileName, line: line)
        default:
            return nil
        }
    }
}

enum ConsoleLinkDetector {
    // [ERROR] /abs/Foo.java:[12,5] message   (Maven)
    private static let mavenError = try! NSRegularExpression(pattern: #"(/[^\[\]:]+\.java):\[(\d+),(\d+)\]"#)
    // /abs/Foo.java:12: error: message          (javac)
    private static let javacError = try! NSRegularExpression(pattern: #"(/[^\s:]+\.java):(\d+):"#)
    // at com.x.Foo.bar(Foo.java:12)
    private static let stackFrame = try! NSRegularExpression(
        pattern: #"at ((?:[\w$]+\.)*[\w$]+)\.[\w$<>]+\(([\w$]+\.java):(\d+)\)"#)

    /// Links in one line of output; ranges are UTF-16 offsets within `line`.
    static func links(in line: String) -> [(range: NSRange, link: ConsoleLink)] {
        let whole = NSRange(location: 0, length: (line as NSString).length)
        let text = line as NSString
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String { text.substring(with: match.range(at: index)) }

        if let match = mavenError.firstMatch(in: line, range: whole) {
            return [(match.range, .file(path: group(match, 1), line: Int(group(match, 2)) ?? 1,
                                        column: Int(group(match, 3)) ?? 1))]
        }
        if let match = javacError.firstMatch(in: line, range: whole) {
            return [(match.range, .file(path: group(match, 1), line: Int(group(match, 2)) ?? 1, column: 1))]
        }
        return stackFrame.matches(in: line, range: whole).map { match in
            // Link only "Foo.java:12", as IntelliJ does.
            let fileAndLine = NSRange(location: match.range(at: 2).location,
                                      length: NSMaxRange(match.range(at: 3)) - match.range(at: 2).location)
            return (fileAndLine, .stackFrame(className: group(match, 1), fileName: group(match, 2),
                                             line: Int(group(match, 3)) ?? 1))
        }
    }
}

/// Maps a stack-frame class to its source file under the project's `src/*/java` roots.
struct SourceLocator {
    private let sourceRoots: [URL]

    init(projectRoot: URL) {
        sourceRoots = Self.findSourceRoots(under: projectRoot)
    }

    func file(forClass className: String, fileName: String) -> URL? {
        // Nested classes (Outer$Inner) live in the outer class's file, whose name the frame gives us.
        var packagePath = className.components(separatedBy: ".").dropLast()
        packagePath.append(fileName)
        let relative = packagePath.joined(separator: "/")
        return sourceRoots
            .map { $0.appendingPathComponent(relative) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `src/main/java`, `src/test/java` and the same inside Maven modules, a few levels deep.
    private static func findSourceRoots(under root: URL, depth: Int = 0) -> [URL] {
        var roots: [URL] = []
        for set in ["main", "test"] {
            let candidate = root.appendingPathComponent("src/\(set)/java")
            if FileManager.default.fileExists(atPath: candidate.path) {
                roots.append(candidate)
            }
        }
        guard depth < 3,
              let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return roots
        }
        for child in children where !["src", "target", "build", "node_modules", "out"].contains(child.lastPathComponent) {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory, FileManager.default.fileExists(atPath: child.appendingPathComponent("pom.xml").path) {
                roots += findSourceRoots(under: child, depth: depth + 1)
            }
        }
        return roots
    }
}
