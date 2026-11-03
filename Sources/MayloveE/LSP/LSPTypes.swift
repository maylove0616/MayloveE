import Foundation

/// Zero-based line and UTF-16 character offset, as in LSP.
struct LSPPosition: Equatable, Sendable {
    let line: Int
    let character: Int

    init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    init?(_ json: JSONValue?) {
        guard let line = json?["line"]?.intValue, let character = json?["character"]?.intValue else { return nil }
        self.init(line: line, character: character)
    }

    var json: JSONValue {
        ["line": .number(Double(line)), "character": .number(Double(character))]
    }
}

struct LSPRange: Equatable, Sendable {
    let start: LSPPosition
    let end: LSPPosition

    init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    init?(_ json: JSONValue?) {
        guard let start = LSPPosition(json?["start"]), let end = LSPPosition(json?["end"]) else { return nil }
        self.init(start: start, end: end)
    }
}

struct LSPLocation: Equatable, Sendable {
    let url: URL
    let range: LSPRange

    init(url: URL, range: LSPRange) {
        self.url = url
        self.range = range
    }

    /// Accepts both `Location` and `LocationLink`.
    init?(_ json: JSONValue) {
        let uri = json["uri"]?.stringValue ?? json["targetUri"]?.stringValue
        let range = LSPRange(json["range"]) ?? LSPRange(json["targetSelectionRange"]) ?? LSPRange(json["targetRange"])
        guard let uri, let url = URL(string: uri), let range else { return nil }
        self.url = url
        self.range = range
    }

    /// Parses `Location | Location[] | LocationLink[] | null`.
    static func list(from json: JSONValue) -> [LSPLocation] {
        if let array = json.arrayValue {
            return array.compactMap(LSPLocation.init)
        }
        return LSPLocation(json).map { [$0] } ?? []
    }
}

struct LSPDiagnostic: Equatable, Sendable {
    enum Severity: Int, Sendable {
        case error = 1, warning, information, hint
    }

    let range: LSPRange
    let severity: Severity
    let message: String

    init?(_ json: JSONValue) {
        guard let range = LSPRange(json["range"]), let message = json["message"]?.stringValue else { return nil }
        self.range = range
        self.severity = json["severity"]?.intValue.flatMap(Severity.init) ?? .error
        self.message = message
    }
}

struct LSPTextEdit: Equatable, Sendable {
    let range: LSPRange
    let newText: String

    init?(_ json: JSONValue?) {
        guard let range = LSPRange(json?["range"]), let newText = json?["newText"]?.stringValue else { return nil }
        self.range = range
        self.newText = newText
    }
}

struct LSPCompletionItem: Sendable {
    let label: String
    let detail: String?
    let filterText: String
    let sortText: String
    let textEdit: LSPTextEdit?
    let insertText: String
    let additionalTextEdits: [LSPTextEdit]
    /// The original item, needed for `completionItem/resolve`.
    let raw: JSONValue

    init?(_ json: JSONValue) {
        guard let label = json["label"]?.stringValue else { return nil }
        self.label = label
        self.detail = json["detail"]?.stringValue
        self.filterText = json["filterText"]?.stringValue ?? label
        self.sortText = json["sortText"]?.stringValue ?? label
        // InsertReplaceEdit carries `insert` instead of `range`.
        let edit = json["textEdit"]
        self.textEdit = LSPTextEdit(edit)
            ?? edit?["insert"].flatMap { LSPTextEdit(["range": $0, "newText": edit?["newText"] ?? ""]) }
        self.insertText = textEdit?.newText ?? json["insertText"]?.stringValue ?? label
        self.additionalTextEdits = json["additionalTextEdits"]?.arrayValue?.compactMap(LSPTextEdit.init) ?? []
        self.raw = json
    }

    /// Parses `CompletionItem[] | CompletionList | null`.
    static func list(from json: JSONValue) -> [LSPCompletionItem] {
        let items = json.arrayValue ?? json["items"]?.arrayValue ?? []
        return items.compactMap(LSPCompletionItem.init)
    }
}

enum HoverPart: Equatable, Sendable {
    /// A code snippet such as a signature.
    case code(String)
    case markdown(String)
    case plain(String)
}

enum LSPHover {
    /// Parses `MarkupContent | MarkedString | MarkedString[]`, dropping empty parts.
    static func parts(from json: JSONValue) -> [HoverPart] {
        guard let contents = json["contents"] else { return [] }
        return (contents.arrayValue ?? [contents]).compactMap { part -> HoverPart? in
            if let markdown = part.stringValue {
                return .markdown(markdown)
            }
            guard let value = part["value"]?.stringValue else { return nil }
            if part["language"] != nil {
                return .code(value)
            }
            return part["kind"]?.stringValue == "plaintext" ? .plain(value) : .markdown(value)
        }
        .filter { part in
            switch part {
            case .code(let text), .markdown(let text), .plain(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }
}
