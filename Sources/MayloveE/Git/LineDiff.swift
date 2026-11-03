import Foundation

/// A block of differing lines: `old` lines were replaced by `new` lines (either may be empty).
struct LineHunk: Equatable, Sendable {
    let old: Range<Int>
    let new: Range<Int>

    enum Kind { case inserted, deleted, modified }

    var kind: Kind {
        if old.isEmpty { return .inserted }
        if new.isEmpty { return .deleted }
        return .modified
    }
}

/// Myers' O(ND) line diff.
enum LineDiff {
    static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)[...].map { $0 }
    }

    static func hunks(old: String, new: String) -> [LineHunk] {
        hunks(old: lines(old), new: lines(new))
    }

    static func hunks(old: [Substring], new: [Substring]) -> [LineHunk] {
        // Common prefix and suffix are cheap to strip and keep the search small for typical edits.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        let a = Array(old[prefix..<(old.count - suffix)])
        let b = Array(new[prefix..<(new.count - suffix)])
        if a.isEmpty && b.isEmpty { return [] }
        if a.isEmpty || b.isEmpty {
            return [LineHunk(old: prefix..<(prefix + a.count), new: prefix..<(prefix + b.count))]
        }

        let matches = matchingPairs(a, b)
        var hunks: [LineHunk] = []
        var oldIndex = 0
        var newIndex = 0
        for (matchOld, matchNew) in matches + [(a.count, b.count)] {
            if matchOld > oldIndex || matchNew > newIndex {
                hunks.append(LineHunk(old: (prefix + oldIndex)..<(prefix + matchOld),
                                      new: (prefix + newIndex)..<(prefix + matchNew)))
            }
            oldIndex = matchOld + 1
            newIndex = matchNew + 1
        }
        return hunks
    }

    /// Beyond this many edits the files are treated as entirely replaced, bounding time and memory.
    private static let maxEditDistance = 4000

    /// Indices of equal lines on the shortest edit script, in order.
    private static func matchingPairs(_ a: [Substring], _ b: [Substring]) -> [(Int, Int)] {
        let n = a.count
        let m = b.count
        let max = n + m
        let offset = max + 1
        var v = [Int](repeating: 0, count: 2 * max + 3)
        // trace[d] holds v[-d-1...d+1] as it was before step d: all that backtracking reads.
        var trace: [[Int]] = []

        search: for d in 0...max {
            guard d <= maxEditDistance else { return [] }
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m { break search }
            }
        }

        // Walk the trace backwards, collecting the diagonal (equal) moves.
        var pairs: [(Int, Int)] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let slice = trace[d]
            let at = { (k: Int) in slice[k + d + 1] }
            let k = x - y
            let previousK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
            let previousX = d == 0 ? 0 : at(previousK)
            let previousY = previousX - previousK
            while x > previousX && y > previousY {
                x -= 1
                y -= 1
                pairs.append((x, y))
            }
            if d > 0 {
                x = previousX
                y = previousY
            }
        }
        return pairs.reversed()
    }
}
