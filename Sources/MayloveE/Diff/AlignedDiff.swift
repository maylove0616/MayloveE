import Foundation

/// Two texts laid out side by side: changed blocks are padded with blank filler rows so that
/// row N on the left lines up with row N on the right.
struct AlignedDiff: Equatable {
    struct Side: Equatable {
        var lines: [String] = []
        /// 1-based line numbers; nil for filler rows.
        var numbers: [Int?] = []

        var text: String { lines.joined(separator: "\n") }
        var labels: [String] { numbers.map { $0.map(String.init) ?? "" } }
    }

    struct Block: Equatable {
        let rows: Range<Int>
        let kind: LineHunk.Kind
    }

    var left = Side()
    var right = Side()
    var blocks: [Block] = []

    init(old: String, new: String) {
        let oldLines = LineDiff.lines(old)
        let newLines = LineDiff.lines(new)
        var oldIndex = 0
        var newIndex = 0
        for hunk in LineDiff.hunks(old: oldLines, new: newLines) {
            appendEqual(oldLines[oldIndex..<hunk.old.lowerBound], from: oldIndex,
                        newFrom: newIndex)
            let start = left.lines.count
            let height = max(hunk.old.count, hunk.new.count)
            for offset in 0..<height {
                Self.append(to: &left, oldLines, hunk.old.lowerBound + offset, in: hunk.old)
                Self.append(to: &right, newLines, hunk.new.lowerBound + offset, in: hunk.new)
            }
            blocks.append(Block(rows: start..<(start + height), kind: hunk.kind))
            oldIndex = hunk.old.upperBound
            newIndex = hunk.new.upperBound
        }
        appendEqual(oldLines[oldIndex...], from: oldIndex, newFrom: newIndex)
    }

    private mutating func appendEqual(_ lines: ArraySlice<Substring>, from oldStart: Int, newFrom newStart: Int) {
        for (offset, line) in lines.enumerated() {
            left.lines.append(String(line))
            left.numbers.append(oldStart + offset + 1)
            right.lines.append(String(line))
            right.numbers.append(newStart + offset + 1)
        }
    }

    private static func append(to side: inout Side, _ lines: [Substring], _ index: Int, in range: Range<Int>) {
        if range.contains(index) {
            side.lines.append(String(lines[index]))
            side.numbers.append(index + 1)
        } else {
            side.lines.append("")
            side.numbers.append(nil)
        }
    }
}
