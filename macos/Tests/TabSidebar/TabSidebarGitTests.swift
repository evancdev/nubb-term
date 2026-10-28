import Foundation
import Testing
@testable import Nubb

@Suite
struct TabSidebarGitTests {
    // MARK: Fixture helpers

    /// Creates a unique directory under the system temp directory, runs
    /// `body`, and removes the directory afterwards.
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nubb-tab-sidebar-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try makeDirectory(url.deletingLastPathComponent())
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Makes `directory` a repo with a `.git` directory whose HEAD is `head`.
    private func makeRepository(at directory: URL, head: String) throws {
        let gitDirectory = directory.appendingPathComponent(".git", isDirectory: true)
        try makeDirectory(gitDirectory)
        try write(head, to: gitDirectory.appendingPathComponent("HEAD"))
    }

    /// True if `directory` or any parent up to `/` has a `.git` entry.
    private func hasGitAncestor(_ directory: URL) -> Bool {
        var current = directory.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return true
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return false }
            current = parent
        }
    }

    // MARK: .git directory

    @Test func branchFromGitDirectory() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/main\n")
            #expect(TabSidebarGit.branch(atDirectory: root) == "main")
        }
    }

    @Test func nestedSubdirectoryWalksUpToRepository() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/develop\n")
            let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
            try makeDirectory(nested)
            #expect(TabSidebarGit.branch(atDirectory: nested) == "develop")
        }
    }

    @Test func nearestRepositoryWins() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/outer\n")
            let inner = root.appendingPathComponent("inner", isDirectory: true)
            try makeRepository(at: inner, head: "ref: refs/heads/inner\n")
            let nested = inner.appendingPathComponent("src", isDirectory: true)
            try makeDirectory(nested)
            #expect(TabSidebarGit.branch(atDirectory: nested) == "inner")
        }
    }

    @Test func branchNameWithSlashes() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/feat/tab-sidebar\n")
            #expect(TabSidebarGit.branch(atDirectory: root) == "feat/tab-sidebar")
        }
    }

    @Test func headIsTrimmedOfSurroundingWhitespace() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "  \n ref: refs/heads/main \n\n")
            #expect(TabSidebarGit.branch(atDirectory: root) == "main")
        }
    }

    @Test func headWithoutTrailingNewline() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/main")
            #expect(TabSidebarGit.branch(atDirectory: root) == "main")
        }
    }

    @Test func otherRefIsReturnedAsWritten() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/remotes/origin/main\n")
            #expect(TabSidebarGit.branch(atDirectory: root) == "refs/remotes/origin/main")
        }
    }

    @Test func tagRefIsReturnedAsWritten() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/tags/v1.0\n")
            #expect(TabSidebarGit.branch(atDirectory: root) == "refs/tags/v1.0")
        }
    }

    // MARK: Detached HEAD

    @Test func detachedSha1HeadReturnsSevenCharacters() throws {
        try withTemporaryDirectory { root in
            let sha = "0123456789abcdef0123456789abcdef01234567"
            #expect(sha.count == 40)
            try makeRepository(at: root, head: sha + "\n")
            #expect(TabSidebarGit.branch(atDirectory: root) == "0123456")
        }
    }

    @Test func detachedSha256HeadReturnsSevenCharacters() throws {
        try withTemporaryDirectory { root in
            let sha = String(repeating: "fedcba98", count: 8)
            #expect(sha.count == 64)
            try makeRepository(at: root, head: sha + "\n")
            #expect(TabSidebarGit.branch(atDirectory: root) == "fedcba9")
        }
    }

    @Test func hexOfOtherLengthReturnsNil() throws {
        try withTemporaryDirectory { root in
            // 41 hex characters: neither a sha1 nor a sha256 object id.
            try makeRepository(at: root, head: String(repeating: "a", count: 41) + "\n")
            #expect(TabSidebarGit.branch(atDirectory: root) == nil)
        }
    }

    @Test func fortyNonHexCharactersReturnNil() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: String(repeating: "z", count: 40) + "\n")
            #expect(TabSidebarGit.branch(atDirectory: root) == nil)
        }
    }

    @Test func garbageHeadReturnsNil() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "not a ref\n")
            #expect(TabSidebarGit.branch(atDirectory: root) == nil)
        }
    }

    @Test func emptyHeadReturnsNil() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "\n")
            #expect(TabSidebarGit.branch(atDirectory: root) == nil)
        }
    }

    // MARK: .git file

    @Test func gitFileWithAbsoluteGitdir() throws {
        try withTemporaryDirectory { root in
            let gitdir = root.appendingPathComponent("storage/worktrees/wt", isDirectory: true)
            try makeDirectory(gitdir)
            try write("ref: refs/heads/worktree-branch\n", to: gitdir.appendingPathComponent("HEAD"))

            let worktree = root.appendingPathComponent("checkout", isDirectory: true)
            try makeDirectory(worktree)
            try write("gitdir: \(gitdir.path)\n", to: worktree.appendingPathComponent(".git"))

            #expect(TabSidebarGit.branch(atDirectory: worktree) == "worktree-branch")
        }
    }

    @Test func gitFileWithRelativeGitdirResolvesAgainstItsDirectory() throws {
        try withTemporaryDirectory { root in
            let gitdir = root.appendingPathComponent(".git/modules/sub", isDirectory: true)
            try makeDirectory(gitdir)
            try write("ref: refs/heads/submodule-branch\n", to: gitdir.appendingPathComponent("HEAD"))

            let submodule = root.appendingPathComponent("sub", isDirectory: true)
            try makeDirectory(submodule)
            try write("gitdir: ../.git/modules/sub\n", to: submodule.appendingPathComponent(".git"))

            let nested = submodule.appendingPathComponent("deep/er", isDirectory: true)
            try makeDirectory(nested)

            // Resolved against `sub/`, not against the starting directory.
            #expect(TabSidebarGit.branch(atDirectory: nested) == "submodule-branch")
            #expect(TabSidebarGit.branch(atDirectory: submodule) == "submodule-branch")
        }
    }

    @Test func gitFileDetachedHead() throws {
        try withTemporaryDirectory { root in
            let gitdir = root.appendingPathComponent("gitdirs/wt", isDirectory: true)
            try makeDirectory(gitdir)
            try write("abcdef0123456789abcdef0123456789abcdef01\n", to: gitdir.appendingPathComponent("HEAD"))

            let worktree = root.appendingPathComponent("wt", isDirectory: true)
            try makeDirectory(worktree)
            try write("gitdir: \(gitdir.path)\n", to: worktree.appendingPathComponent(".git"))

            #expect(TabSidebarGit.branch(atDirectory: worktree) == "abcdef0")
        }
    }

    @Test func malformedGitFileReturnsNilWithoutSearchingParents() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/parent\n")
            let child = root.appendingPathComponent("child", isDirectory: true)
            try makeDirectory(child)
            try write("this is not a gitdir line\n", to: child.appendingPathComponent(".git"))

            #expect(TabSidebarGit.branch(atDirectory: child) == nil)
        }
    }

    @Test func emptyGitFileReturnsNilWithoutSearchingParents() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/parent\n")
            let child = root.appendingPathComponent("child", isDirectory: true)
            try makeDirectory(child)
            try write("", to: child.appendingPathComponent(".git"))

            #expect(TabSidebarGit.branch(atDirectory: child) == nil)
        }
    }

    @Test func gitFilePointingAtMissingHeadReturnsNil() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/parent\n")
            let child = root.appendingPathComponent("child", isDirectory: true)
            try makeDirectory(child)
            let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
            try write("gitdir: \(missing.path)\n", to: child.appendingPathComponent(".git"))

            #expect(TabSidebarGit.branch(atDirectory: child) == nil)
        }
    }

    // MARK: Missing HEAD

    @Test func missingHeadReturnsNilWithoutSearchingParents() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/parent\n")
            let child = root.appendingPathComponent("child", isDirectory: true)
            // `.git` directory exists but has no HEAD.
            try makeDirectory(child.appendingPathComponent(".git", isDirectory: true))

            #expect(TabSidebarGit.branch(atDirectory: child) == nil)
            // Sanity: the parent repo is valid on its own.
            #expect(TabSidebarGit.branch(atDirectory: root) == "parent")
        }
    }

    @Test func missingHeadFromNestedDirectoryReturnsNil() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/parent\n")
            let child = root.appendingPathComponent("child", isDirectory: true)
            try makeDirectory(child.appendingPathComponent(".git", isDirectory: true))
            let nested = child.appendingPathComponent("src/lib", isDirectory: true)
            try makeDirectory(nested)

            #expect(TabSidebarGit.branch(atDirectory: nested) == nil)
        }
    }

    // MARK: No repository

    @Test func noRepositoryReturnsNil() throws {
        try withTemporaryDirectory { root in
            let nested = root.appendingPathComponent("x/y", isDirectory: true)
            try makeDirectory(nested)
            // The answer is only defined as nil if nothing up to `/` is a
            // repo. The system temp directory is normally outside any repo,
            // but that cannot be guaranteed on every machine, so skip the
            // assertion if an ancestor has a `.git` entry.
            guard !hasGitAncestor(nested) else { return }
            #expect(TabSidebarGit.branch(atDirectory: nested) == nil)
        }
    }

    // MARK: File manager injection

    @Test func explicitFileManagerIsAccepted() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/main\n")
            #expect(TabSidebarGit.branch(atDirectory: root, fileManager: FileManager()) == "main")
        }
    }
}
