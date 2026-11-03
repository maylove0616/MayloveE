import Foundation

/// UTF-16 offsets of every line start, for mapping character offsets to line numbers.
struct LineIndex {
    private(set) var lineStarts: [Int]
    /// Total UTF-16 length of the text.
    let length: Int

    init(_ text: String) {
        var starts = [0]
        var length = 0
        for unit in text.utf16 {
            length += 1
            if unit == 0x0A {
                starts.append(length)
            }
        }
        lineStarts = starts
        self.length = length
    }

    var lineCount: Int { lineStarts.count }

    /// Zero-based line containing the given UTF-16 offset.
    func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    func position(of offset: Int) -> LSPPosition {
        let line = line(containing: offset)
        return LSPPosition(line: line, character: offset - lineStarts[line])
    }

    /// Clamps positions past the end of a line or of the document, as LSP requires.
    func offset(of position: LSPPosition) -> Int {
        guard position.line < lineStarts.count else { return length }
        let start = lineStarts[max(position.line, 0)]
        let lineEnd = position.line + 1 < lineStarts.count ? lineStarts[position.line + 1] - 1 : length
        return min(start + max(position.character, 0), lineEnd)
    }

    func range(of lspRange: LSPRange) -> NSRange {
        let start = offset(of: lspRange.start)
        let end = max(start, offset(of: lspRange.end))
        return NSRange(location: start, length: end - start)
    }
}
