import Foundation
import os

/// A Git working tree: cached status and branches, plus the operations the IDE offers.
@MainActor
final class GitRepository {
    private static let logger = Logger(subsystem: "MayloveE", category: "Git")

    /// The working tree's top level, which may be above the opened folder.
    let root: URL
    private let client: GitClient

    private(set) var status = GitStatus()
    private(set) var branches: [GitBranch] = []
    /// Called after a refresh that changed the status or branches.
    var onChange: (() -> Void)?

    private var changesByPath: [String: GitFileChange] = [:]
    private var isRefreshing = false
    private var needsAnotherRefresh = false

    private init(root: URL) {
        self.root = root
        client = GitClient(directory: root)
    }

    /// The repository containing `url`, or nil if it is not in a Git working tree.
    static func open(containing url: URL) async -> GitRepository? {
        do {
            let topLevel = try await GitClient(directory: url).output(["rev-parse", "--show-toplevel"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let repository = GitRepository(root: URL(fileURLWithPath: topLevel).resolvingSymlinksInPath())
            await repository.refresh()
            return repository
        } catch {
            return nil
        }
    }

    /// `git init` in `url`, as IntelliJ's "Create Git Repository".
    static func initialize(at url: URL) async throws -> GitRepository {
        _ = try await GitClient(directory: url).run(["init"])
        guard let repository = await open(containing: url) else {
            throw GitClient.Failure(arguments: ["init"], status: 0, output: "git init did not create a repository")
        }
        return repository
    }

    // MARK: - State

    /// Re-reads status and branches; concurrent calls coalesce into one extra pass.
    func refresh() async {
        if isRefreshing {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsAnotherRefresh = false
            do {
                async let statusOutput = client.output(GitStatus.arguments)
                async let branchOutput = client.output(GitBranch.arguments)
                let newStatus = GitStatus.parse(try await statusOutput)
                let newBranches = GitBranch.parse(try await branchOutput)
                guard newStatus != status || newBranches != branches else { continue }
                status = newStatus
                branches = newBranches
                changesByPath = Dictionary(newStatus.changes.map { ($0.path, $0) }, uniquingKeysWith: { $1 })
                onChange?()
            } catch {
                Self.logger.error("git status failed: \(error.localizedDescription, privacy: .public)")
            }
        } while needsAnotherRefresh
    }

    func change(for url: URL) -> GitFileChange? {
        relativePath(of: url).flatMap { changesByPath[$0] }
    }

    func url(for path: String) -> URL {
        root.appendingPathComponent(path)
    }

    func relativePath(of url: URL) -> String? {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        // git reports the resolved top level, e.g. /private/tmp for /tmp.
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : nil
    }

    // MARK: - Contents

    /// A file at a revision, or nil if it does not exist there.
    func contents(of path: String, at revision: String) async -> String? {
        do {
            return try await client.output(["show", "\(revision):\(path)"])
        } catch {
            return nil
        }
    }

    /// The committed version of a working-tree file; nil when untracked, added, or not in this repository.
    func headContents(of url: URL) async -> String? {
        guard status.headOID != nil, let path = relativePath(of: url) else { return nil }
        if let change = changesByPath[path], change.kind == .untracked || change.kind == .added {
            return nil
        }
        return await contents(of: path, at: "HEAD")
    }

    // MARK: - Commit and rollback

    /// Commits exactly the given paths, adding untracked ones first, like IntelliJ's commit.
    func commit(message: String, changes: [GitFileChange], amend: Bool = false) async throws {
        let untracked = changes.filter(\.isUntracked).map(\.path)
        if !untracked.isEmpty {
            _ = try await client.run(["add", "--"] + untracked)
        }
        let paths = changes.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        var arguments = ["commit", "-m", message]
        if amend { arguments.append("--amend") }
        // Without paths, an amend only rewrites the message.
        if !paths.isEmpty {
            arguments += ["--only", "--"] + paths
        }
        _ = try await client.run(arguments)
        await refresh()
    }

    /// Discards local changes: tracked files go back to HEAD, untracked files are deleted.
    func rollback(_ changes: [GitFileChange]) async throws {
        let untracked = changes.filter(\.isUntracked).map(\.path)
        let added = changes.filter { $0.kind == .added }.map(\.path)
        let tracked = changes.filter { $0.kind != .untracked && $0.kind != .added }
            .flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        if !added.isEmpty {
            _ = try await client.run(["rm", "--cached", "--quiet", "--"] + added)
        }
        if !tracked.isEmpty {
            _ = try await client.run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + tracked)
        }
        for path in untracked + added {
            try FileManager.default.removeItem(at: url(for: path))
        }
        await refresh()
    }

    // MARK: - Branches

    func checkout(_ branch: GitBranch) async throws {
        if branch.isRemote {
            // Remote branches are checked out as a new local tracking branch.
            let localName = branch.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch.name
            if branches.contains(where: { !$0.isRemote && $0.name == localName }) {
                _ = try await client.run(["switch", localName])
            } else {
                _ = try await client.run(["switch", "--track", "-c", localName, branch.name])
            }
        } else {
            _ = try await client.run(["switch", branch.name])
        }
        await refresh()
    }

    func createBranch(_ name: String) async throws {
        _ = try await client.run(["switch", "-c", name])
        await refresh()
    }

    // MARK: - Remote

    var remotes: [String] {
        get async {
            (try? await client.output(["remote"]))?.split(separator: "\n").map(String.init) ?? []
        }
    }

    /// Commits that a push would send: ahead of the upstream, or not on any remote yet.
    func outgoingCommits() async throws -> [GitCommit] {
        let range = status.upstream == nil ? ["HEAD", "--not", "--remotes"] : ["@{upstream}..HEAD"]
        return GitCommit.parse(try await client.output(GitCommit.logArguments(limit: 100) + range))
    }

    /// Pushes the current branch, setting the upstream on first push.
    func push() async throws -> String {
        guard let branch = status.branch else {
            throw GitClient.Failure(arguments: ["push"], status: 0, output: "Cannot push a detached HEAD.")
        }
        var arguments = ["push", "--porcelain"]
        if status.upstream == nil {
            let remotes = await self.remotes
            guard let remote = remotes.contains("origin") ? "origin" : remotes.first else {
                throw GitClient.Failure(arguments: ["push"], status: 0, output: "No remote is configured.")
            }
            arguments += ["--set-upstream", remote, branch]
        }
        let output = try await client.output(arguments)
        await refresh()
        return output
    }

    /// Merges the upstream into the current branch unless the user configured otherwise,
    /// as IntelliJ's "Update Project" does by default.
    func pull() async throws -> String {
        var arguments = ["pull", "--no-edit"]
        let configured = (try? await client.output(["config", "--get", "pull.rebase"])) != nil
        if !configured {
            arguments.append("--no-rebase")
        }
        let output = try await client.output(arguments)
        await refresh()
        return output
    }

    func fetch() async throws {
        _ = try await client.run(["fetch", "--all", "--prune"])
        await refresh()
    }

    // MARK: - History

    /// The HEAD commit's full message, to prefill an amend.
    func lastCommitMessage() async -> String? {
        guard status.headOID != nil else { return nil }
        return try? await client.output(["log", "-1", "--format=%B"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func log(limit: Int = 1000) async throws -> [GitCommit] {
        guard status.headOID != nil else { return [] }
        return GitCommit.parse(try await client.output(GitCommit.logArguments(limit: limit)))
    }

    func files(in commit: GitCommit) async throws -> [GitFileChange] {
        GitCommitFiles.parse(try await client.output(GitCommitFiles.arguments(for: commit)))
    }
}
