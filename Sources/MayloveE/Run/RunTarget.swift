import Foundation
import SwiftTreeSitter

/// What "Run" means at the caret, mirroring IntelliJ's run-context logic.
enum RunTarget: Equatable, Sendable {
    /// A class with `public static void main`, by fully qualified name.
    case mainClass(String)
    case testClass(String)
    case testMethod(String, method: String)

    var className: String {
        switch self {
        case .mainClass(let name), .testClass(let name), .testMethod(let name, _): return name
        }
    }

    var title: String {
        let simpleName = className.components(separatedBy: ".").last ?? className
        switch self {
        case .mainClass: return "\(simpleName).main()"
        case .testClass: return simpleName
        case .testMethod(_, let method): return "\(simpleName).\(method)"
        }
    }
}

/// Finds the run target for a caret position using the tree-sitter syntax tree.
@MainActor
enum RunTargetResolver {
    private static let testAnnotation = try! NSRegularExpression(
        pattern: #"@(?:[\w.]+\.)?(?:Test|ParameterizedTest|RepeatedTest|TestFactory|TestTemplate)\b"#)

    static func resolve(text: String, caret: Int) -> RunTarget? {
        guard let syntax = JavaSyntax.shared, let tree = syntax.parse(text), let root = tree.rootNode else {
            return nil
        }
        let source = text as NSString
        let packageName = packageName(in: root, source: source)

        let caretBytes = UInt32(caret * 2)
        let caretNode = root.descendant(in: caretBytes..<caretBytes)
        let enclosing = ancestors(of: caretNode)
        // The outermost class: nested classes are rarely run on their own.
        guard let classNode = enclosing.last(where: { $0.nodeType == "class_declaration" })
                ?? topLevelClasses(in: root).first,
              let className = name(of: classNode, source: source) else { return nil }
        let qualifiedName = packageName.map { "\($0).\(className)" } ?? className

        if let method = enclosing.first(where: { $0.nodeType == "method_declaration" }),
           isTest(method, source: source), let methodName = name(of: method, source: source) {
            return .testMethod(qualifiedName, method: methodName)
        }
        let methods = methodDeclarations(in: classNode)
        if methods.contains(where: { isTest($0, source: source) }) {
            return .testClass(qualifiedName)
        }
        if methods.contains(where: { isMain($0, source: source) }) {
            return .mainClass(qualifiedName)
        }
        return nil
    }

    private static func packageName(in root: Node, source: NSString) -> String? {
        for index in 0..<root.namedChildCount {
            guard let child = root.namedChild(at: index), child.nodeType == "package_declaration" else { continue }
            let text = source.substring(with: child.range)
            return text
                .replacingOccurrences(of: "package", with: "")
                .replacingOccurrences(of: ";", with: "")
                .components(separatedBy: .whitespacesAndNewlines).joined()
        }
        return nil
    }

    private static func ancestors(of node: Node?) -> [Node] {
        var result: [Node] = []
        var current = node
        while let node = current {
            result.append(node)
            current = node.parent
        }
        return result
    }

    private static func topLevelClasses(in root: Node) -> [Node] {
        (0..<root.namedChildCount).compactMap { root.namedChild(at: $0) }
            .filter { $0.nodeType == "class_declaration" }
    }

    private static func methodDeclarations(in classNode: Node) -> [Node] {
        guard let body = classNode.child(byFieldName: "body") else { return [] }
        return (0..<body.namedChildCount).compactMap { body.namedChild(at: $0) }
            .filter { $0.nodeType == "method_declaration" }
    }

    private static func name(of node: Node, source: NSString) -> String? {
        node.child(byFieldName: "name").map { source.substring(with: $0.range) }
    }

    private static func modifiers(of method: Node, source: NSString) -> String {
        for index in 0..<method.namedChildCount {
            if let child = method.namedChild(at: index), child.nodeType == "modifiers" {
                return source.substring(with: child.range)
            }
        }
        return ""
    }

    private static func isTest(_ method: Node, source: NSString) -> Bool {
        let text = modifiers(of: method, source: source)
        return testAnnotation.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func isMain(_ method: Node, source: NSString) -> Bool {
        guard name(of: method, source: source) == "main" else { return false }
        let words = modifiers(of: method, source: source).components(separatedBy: .whitespacesAndNewlines)
        return words.contains("static") && words.contains("public")
    }
}
