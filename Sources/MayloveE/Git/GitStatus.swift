import Foundation

/// One changed path, relative to the repository's top level.
struct GitFileChange: Equatable, Sendable {
    enum Kind: Sendable {
        case added
        case modified
        case deleted
        case renamed
        case untracked
        case conflicted
    }

    let path: String
    /// The path before a rename.
    let originalPath: String?
    let kind: Kind

    var isUntracked: Bool { kind == .untracked }
}

/// `git status --porcelain=v2 --branch -z`.
struct GitStatus: Equatable, Sendable {
    /// Nil when HEAD is detached.
    var branch: String?
    /// Nil before the first commit.
    var headOID: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [GitFileChange] = []

    static let arguments = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]

    static func parse(_ output: String) -> GitStatus {
        var status = GitStatus()
        var records = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let record = records.next() {
            let fields = record.split(separator: " ", omittingEmptySubsequences: false)
            guard let type = fields.first else { continue }
            switch type {
            case "#":
                status.parseHeader(fields.dropFirst().map(String.init))
            case "1" where fields.count >= 9:
                let path = fields[8...].joined(separator: " ")
                status.changes.append(GitFileChange(path: path, originalPath: nil, kind: kind(xy: fields[1])))
            case "2" where fields.count >= 10:
                // The original path follows as its own NUL-terminated record.
                let path = fields[9...].joined(separator: " ")
                let originalPath = records.next().map(String.init)
                let xy = fields[1]
                let changeKind: GitFileChange.Kind = xy.contains("D") ? .deleted : .renamed
                status.changes.append(GitFileChange(path: path, originalPath: originalPath, kind: changeKind))
            case "u" where fields.count >= 11:
                let path = fields[10...].joined(separator: " ")
                status.changes.append(GitFileChange(path: path, originalPath: nil, kind: .conflicted))
            case "?":
                let path = record.dropFirst(2)
                status.changes.append(GitFileChange(path: String(path), originalPath: nil, kind: .untracked))
            default:
                continue
            }
        }
        return status
    }

    private mutating func parseHeader(_ fields: [String]) {
        guard fields.count >= 2 else { return }
        switch fields[0] {
        case "branch.oid":
            headOID = fields[1] == "(initial)" ? nil : fields[1]
        case "branch.head":
            branch = fields[1] == "(detached)" ? nil : fields[1...].joined(separator: " ")
        case "branch.upstream":
            upstream = fields[1]
        case "branch.ab" where fields.count >= 3:
            ahead = Int(fields[1].dropFirst()) ?? 0
            behind = Int(fields[2].dropFirst()) ?? 0
        default:
            break
        }
    }

    /// XY: index and worktree state; a deletion on either side wins, then an addition to the index.
    private static func kind(xy: Substring) -> GitFileChange.Kind {
        if xy.contains("D") { return .deleted }
        if xy.first == "A" { return .added }
        return .modified
    }
}

struct GitBranch: Equatable, Sendable {
    /// Short name, e.g. "main" or "origin/main".
    let name: String
    let isRemote: Bool
    let isCurrent: Bool
    /// For a local branch, its upstream such as "origin/main".
    let upstream: String?

    static let arguments = ["for-each-ref", "--format=%(refname)%00%(HEAD)%00%(upstream:short)",
                            "refs/heads", "refs/remotes"]

    static func parse(_ output: String) -> [GitBranch] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { return nil }
            let ref = fields[0]
            if ref.hasPrefix("refs/heads/") {
                return GitBranch(name: String(ref.dropFirst("refs/heads/".count)), isRemote: false,
                                 isCurrent: fields[1] == "*", upstream: fields[2].isEmpty ? nil : fields[2])
            }
            if ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") {
                return GitBranch(name: String(ref.dropFirst("refs/remotes/".count)), isRemote: true,
                                 isCurrent: false, upstream: nil)
            }
            return nil
        }
    }
}

struct GitCommit: Equatable, Sendable {
    let hash: String
    let shortHash: String
    let author: String
    let date: Date
    /// Branch and tag names pointing at this commit, e.g. "HEAD -> main, origin/main".
    let refs: String
    let subject: String
    let parents: [String]

    private static let fieldSeparator: Character = "\u{1F}"
    private static let recordSeparator: Character = "\u{1E}"

    static func logArguments(limit: Int) -> [String] {
        ["log", "-n", String(limit), "--format=%H%x1F%h%x1F%an%x1F%at%x1F%D%x1F%P%x1F%s%x1E"]
    }

    static func parse(_ output: String) -> [GitCommit] {
        output.split(separator: recordSeparator).compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines)
                .split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, let timestamp = TimeInterval(fields[3]) else { return nil }
            return GitCommit(hash: fields[0], shortHash: fields[1], author: fields[2],
                             date: Date(timeIntervalSince1970: timestamp), refs: fields[4],
                             subject: fields[6], parents: fields[5].split(separator: " ").map(String.init))
        }
    }
}

/// `git diff-tree --name-status -z` output for one commit.
enum GitCommitFiles {
    static func arguments(for commit: GitCommit) -> [String] {
        // --root lists the files of a first commit against the empty tree.
        ["diff-tree", "--no-commit-id", "-r", "-M", "--name-status", "-z", "--root", commit.hash]
    }

    static func parse(_ output: String) -> [GitFileChange] {
        var changes: [GitFileChange] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init).makeIterator()
        while let status = fields.next(), let first = status.first {
            switch first {
            case "R", "C":
                guard let original = fields.next(), let path = fields.next() else { return changes }
                changes.append(GitFileChange(path: path, originalPath: original, kind: .renamed))
            default:
                guard let path = fields.next() else { return changes }
                let kind: GitFileChange.Kind = first == "A" ? .added : first == "D" ? .deleted : .modified
                changes.append(GitFileChange(path: path, originalPath: nil, kind: kind))
            }
        }
        return changes
    }
}
