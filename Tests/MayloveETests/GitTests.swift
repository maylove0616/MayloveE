import Foundation
import Testing
@testable import MayloveE

struct LineDiffTests {
    @Test func classifiesInsertDeleteAndModify() {
        let old = "a\nb\nc\nd\ne"
        let new = "a\nB\nc\ne\nf"
        #expect(LineDiff.hunks(old: old, new: new) == [
            LineHunk(old: 1..<2, new: 1..<2),
            LineHunk(old: 3..<4, new: 3..<3),
            LineHunk(old: 5..<5, new: 4..<5),
        ])
        #expect(LineDiff.hunks(old: old, new: new).map(\.kind) == [.modified, .deleted, .inserted])
    }

    @Test func identicalTextsHaveNoHunks() {
        #expect(LineDiff.hunks(old: "x\ny\n", new: "x\ny\n").isEmpty)
    }

    @Test func findsMinimalEditInsideRepeatedLines() {
        let old = (0..<200).map { "line \($0 % 7)" }.joined(separator: "\n")
        var lines = old.components(separatedBy: "\n")
        lines.insert("inserted", at: 120)
        lines.remove(at: 30)
        let hunks = LineDiff.hunks(old: old, new: lines.joined(separator: "\n"))
        let changedLines = hunks.reduce(0) { $0 + $1.old.count + $1.new.count }
        #expect(changedLines == 2)
    }

    @Test func applyingHunksReproducesNewText() {
        let old = (0..<60).map { "l\($0 % 5)" }
        var new = old
        new.replaceSubrange(10..<14, with: ["x", "y"])
        new.insert(contentsOf: ["p", "q", "r"], at: 40)
        new.removeLast(3)
        let hunks = LineDiff.hunks(old: old.map { Substring($0) }, new: new.map { Substring($0) })
        var rebuilt: [String] = []
        var oldIndex = 0
        for hunk in hunks {
            rebuilt += old[oldIndex..<hunk.old.lowerBound]
            rebuilt += new[hunk.new]
            oldIndex = hunk.old.upperBound
        }
        rebuilt += old[oldIndex...]
        #expect(rebuilt == new)
    }
}

struct GitStatusParserTests {
    @Test func parsesBranchHeadersAndEntries() {
        let output = [
            "# branch.oid 1234abcd",
            "# branch.head feature/x",
            "# branch.upstream origin/feature/x",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa bbb src/My File.java",
            "1 A. N... 000000 100644 100644 000 bbb new.txt",
            "1 .D N... 100644 100644 000000 aaa aaa gone.txt",
            "2 R. N... 100644 100644 100644 aaa aaa R100 renamed.txt",
            "old.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
            "? untracked dir/file.md",
        ].joined(separator: "\0") + "\0"
        let status = GitStatus.parse(output)
        #expect(status.branch == "feature/x")
        #expect(status.headOID == "1234abcd")
        #expect(status.upstream == "origin/feature/x")
        #expect(status.ahead == 2 && status.behind == 1)
        #expect(status.changes == [
            GitFileChange(path: "src/My File.java", originalPath: nil, kind: .modified),
            GitFileChange(path: "new.txt", originalPath: nil, kind: .added),
            GitFileChange(path: "gone.txt", originalPath: nil, kind: .deleted),
            GitFileChange(path: "renamed.txt", originalPath: "old.txt", kind: .renamed),
            GitFileChange(path: "conflict.txt", originalPath: nil, kind: .conflicted),
            GitFileChange(path: "untracked dir/file.md", originalPath: nil, kind: .untracked),
        ])
    }

    @Test func initialAndDetached() {
        let status = GitStatus.parse("# branch.oid (initial)\0# branch.head (detached)\0")
        #expect(status.headOID == nil)
        #expect(status.branch == nil)
    }
}

/// Real git against throwaway repositories; a bare repository stands in for the remote.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct GitRepositoryTests {
    private func makeRepository() async throws -> (URL, GitRepository) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MayloveE-Git-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await git(["init", "-b", "main"], in: directory)
        try await configureIdentity(directory)
        try "one\ntwo\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: directory)
        try await git(["commit", "-m", "initial"], in: directory)
        let repository = try #require(await GitRepository.open(containing: directory))
        return (directory, repository)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        try await GitClient(directory: directory).output(arguments)
    }

    private func configureIdentity(_ directory: URL) async throws {
        try await git(["config", "user.name", "Test"], in: directory)
        try await git(["config", "user.email", "test@example.com"], in: directory)
    }

    @Test func commitsOnlySelectedFilesIncludingUntracked() async throws {
        let (directory, repository) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "one\nTWO\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "later\n".write(to: directory.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        await repository.refresh()
        #expect(repository.change(for: directory.appendingPathComponent("a.txt"))?.kind == .modified)
        #expect(repository.change(for: directory.appendingPathComponent("b.txt"))?.kind == .untracked)
        #expect(await repository.headContents(of: directory.appendingPathComponent("a.txt")) == "one\ntwo\n")

        let selected = repository.status.changes.filter { $0.path != "c.txt" }
        try await repository.commit(message: "Change a, add b", changes: selected)

        #expect(repository.status.changes == [GitFileChange(path: "c.txt", originalPath: nil, kind: .untracked)])
        let log = try await repository.log()
        #expect(log.map(\.subject) == ["Change a, add b", "initial"])
        let files = try await repository.files(in: log[0])
        #expect(Set(files.map(\.path)) == ["a.txt", "b.txt"])
    }

    @Test func rollbackRestoresTrackedAndDeletesUntracked() async throws {
        let (directory, repository) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.txt")
        let b = directory.appendingPathComponent("b.txt")
        try "changed\n".write(to: a, atomically: true, encoding: .utf8)
        try "new\n".write(to: b, atomically: true, encoding: .utf8)
        await repository.refresh()

        try await repository.rollback(repository.status.changes)

        #expect(try String(contentsOf: a, encoding: .utf8) == "one\ntwo\n")
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(repository.status.changes.isEmpty)
    }

    @Test func branchesPushAndPull() async throws {
        let (directory, repository) = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = directory.appendingPathExtension("remote.git")
        defer { try? FileManager.default.removeItem(at: remote) }
        try await git(["init", "--bare", "-b", "main", remote.path], in: directory)
        try await git(["remote", "add", "origin", remote.path], in: directory)

        // First push sets the upstream.
        #expect(try await repository.outgoingCommits().count == 1)
        _ = try await repository.push()
        #expect(repository.status.upstream == "origin/main")
        #expect(repository.branches.contains { $0.isRemote && $0.name == "origin/main" })

        try await repository.createBranch("feature")
        #expect(repository.status.branch == "feature")
        let main = try #require(repository.branches.first { !$0.isRemote && $0.name == "main" })
        try await repository.checkout(main)
        #expect(repository.status.branch == "main")

        // Another clone pushes a commit; pull brings it in.
        let other = directory.appendingPathExtension("other")
        defer { try? FileManager.default.removeItem(at: other) }
        try await git(["clone", remote.path, other.path], in: directory)
        try await configureIdentity(other)
        try "three\n".write(to: other.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: other)
        try await git(["commit", "-m", "from other"], in: other)
        try await git(["push"], in: other)

        try await repository.fetch()
        #expect(repository.status.behind == 1)
        _ = try await repository.pull()
        #expect(repository.status.behind == 0)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("c.txt").path))
    }

    @Test func notARepository() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MayloveE-NoGit-\(UUID())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await GitRepository.open(containing: directory) == nil)
    }
}

struct AlignedDiffTests {
    @Test func padsChangedBlocksSoRowsLineUp() {
        let diff = AlignedDiff(old: "a\nb\nc\nd", new: "a\nB\nB2\nc")
        #expect(diff.left.lines == ["a", "b", "", "c", "d"])
        #expect(diff.right.lines == ["a", "B", "B2", "c", ""])
        #expect(diff.left.numbers == [1, 2, nil, 3, 4])
        #expect(diff.right.numbers == [1, 2, 3, 4, nil])
        #expect(diff.blocks == [
            AlignedDiff.Block(rows: 1..<3, kind: .modified),
            AlignedDiff.Block(rows: 4..<5, kind: .deleted),
        ])
    }
}
