import Foundation
import os
import SwiftTreeSitter
import TreeSitterJava

/// Tree-sitter parser and highlight query for Java, shared by all editors.
@MainActor
final class JavaSyntax {
    static let shared: JavaSyntax? = JavaSyntax()

    private static let logger = Logger(subsystem: "MayloveE", category: "JavaSyntax")
    private static let queriesBundleName = "TreeSitterJava_TreeSitterJava.bundle"

    private let parser = Parser()
    private let highlightsQuery: Query

    private init?() {
        let language = Language(tree_sitter_java())
        guard let queriesURL = Self.locateQueries() else {
            Self.logger.error("Cannot find \(Self.queriesBundleName, privacy: .public); Java highlighting disabled")
            return nil
        }
        do {
            let configuration = try LanguageConfiguration(language, name: "Java", queriesURL: queriesURL)
            guard let query = configuration.queries[.highlights] else {
                Self.logger.error("highlights.scm missing in \(queriesURL.path, privacy: .public)")
                return nil
            }
            try parser.setLanguage(language)
            highlightsQuery = query
        } catch {
            Self.logger.error("Cannot load Java grammar: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func parse(_ text: String) -> MutableTree? {
        parser.parse(text)
    }

    /// Highlight captures intersecting `range`, ordered from least to most specific.
    func highlights(in tree: MutableTree, text: String, range: NSRange) -> [NamedRange] {
        let cursor = highlightsQuery.execute(in: tree)
        cursor.setRange(range)
        return cursor.resolve(with: Predicate.Context(string: text)).highlights()
    }

    /// SwiftPM places resource bundles in Contents/Resources inside an .app,
    /// but next to the executable (or test bundle) during `swift run` / `swift test`.
    private static func locateQueries() -> URL? {
        let containers = [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: JavaSyntax.self).bundleURL.deletingLastPathComponent(),
        ]
        for container in containers.compactMap({ $0 }) {
            let bundleURL = container.appendingPathComponent(queriesBundleName)
            guard let queries = Bundle(url: bundleURL)?.resourceURL?.appendingPathComponent("queries") else {
                continue
            }
            if FileManager.default.fileExists(atPath: queries.path) {
                return queries
            }
        }
        return nil
    }
}
