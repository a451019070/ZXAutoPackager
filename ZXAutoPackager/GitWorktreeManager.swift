import Foundation

struct GitWorktreeContext: Sendable {
    let repositoryRoot: URL
    let worktreeRoot: URL
    let projectDirectory: URL
}

struct GitMergeConflict: Error, Sendable {
    let context: GitWorktreeContext
    let branch: String
    let nextIndex: Int
    let files: [String]
    let output: String
}

enum GitPreparationError: LocalizedError {
    case commandFailed(String, Int32, String)
    case invalidRepository
    case invalidProjectPath
    case noRemoteBranches
    case unresolvedConflicts([String])
    case mergeNoLongerInProgress
    case podfileNotFound
    case cancelled

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let code, let output):
            return "命令执行失败（\(code)）：\(command)\n\(output)"
        case .invalidRepository:
            return "所选项目不在 Git 仓库中。"
        case .invalidProjectPath:
            return "无法确定项目相对于 Git 仓库的位置。"
        case .noRemoteBranches:
            return "没有找到 origin 远程分支。"
        case .unresolvedConflicts(let files):
            return "仍有未解决的冲突文件，请修改并执行 git add：\n\(files.joined(separator: "\n"))"
        case .mergeNoLongerInProgress:
            return "合并状态已改变（可能执行了 merge --abort 或 reset）。请放弃并重新准备。"
        case .podfileNotFound:
            return "临时项目目录中没有找到 Podfile。"
        case .cancelled:
            return "代码准备已停止。"
        }
    }
}

nonisolated enum GitWorktreeManager {
    static func listRemoteBranches(
        projectPath: String,
        fetchRemote: Bool
    ) throws -> [String] {
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        let root = try repositoryRoot(for: projectURL)

        if fetchRemote {
            let fetch = try run(
                executable: "/usr/bin/git",
                arguments: ["-C", root.path, "fetch", "origin", "--prune"]
            )
            guard fetch.status == 0 else {
                throw GitPreparationError.commandFailed("git fetch origin --prune", fetch.status, fetch.output)
            }
        }

        let result = try run(
            executable: "/usr/bin/git",
            arguments: [
                "-C", root.path,
                "for-each-ref",
                "--format=%(refname:strip=3)",
                "refs/remotes/origin"
            ]
        )
        guard result.status == 0 else {
            throw GitPreparationError.commandFailed("读取远程分支", result.status, result.output)
        }

        let branches = result.output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "HEAD" }
            .sorted()
        guard !branches.isEmpty else { throw GitPreparationError.noRemoteBranches }
        return branches
    }

    static func prepare(
        projectPath: String,
        branch: String,
        mergeBranches: [String],
        installPods: Bool,
        cancellation: BuildCancellationController,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> GitWorktreeContext {
        guard !cancellation.isCancelled else { throw GitPreparationError.cancelled }

        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        let root = try repositoryRoot(for: projectURL)
        guard let relativeProjectPath = relativePath(of: projectURL, from: root) else {
            throw GitPreparationError.invalidProjectPath
        }

        let temporaryParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZXAutoPackager-Worktrees", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryParent,
            withIntermediateDirectories: true
        )
        let worktreeRoot = temporaryParent
            .appendingPathComponent("\(root.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        var prepared = false
        defer {
            if !prepared { cleanup(repositoryRoot: root, worktreeRoot: worktreeRoot) }
        }

        onOutput("===== 准备分支代码 =====\n")
        onOutput("创建独立 Worktree：origin/\(branch)\n")
        let worktreeResult = try run(
            executable: "/usr/bin/git",
            arguments: [
                "-C", root.path,
                "worktree", "add", "--detach",
                worktreeRoot.path,
                "refs/remotes/origin/\(branch)"
            ],
            cancellation: cancellation
        )
        guard !cancellation.isCancelled else {
            throw GitPreparationError.cancelled
        }
        guard worktreeResult.status == 0 else {
            throw GitPreparationError.commandFailed(
                "git worktree add --detach origin/\(branch)",
                worktreeResult.status,
                worktreeResult.output
            )
        }

        let temporaryProjectURL = relativeProjectPath.isEmpty
            ? worktreeRoot
            : worktreeRoot.appendingPathComponent(relativeProjectPath, isDirectory: true)
        let context = GitWorktreeContext(repositoryRoot: root, worktreeRoot: worktreeRoot,
                                         projectDirectory: temporaryProjectURL)

        var merged = Set<String>()
        for (index, mergeBranch) in mergeBranches.enumerated() {
            guard !mergeBranch.isEmpty, mergeBranch != branch, merged.insert(mergeBranch).inserted else {
                throw GitPreparationError.commandFailed("合并远程分支", 1, "待合并分支不能为空、重复或与打包分支相同。")
            }
            guard !cancellation.isCancelled else { throw GitPreparationError.cancelled }
            onOutput("合并第 \(index + 1)/\(mergeBranches.count) 个分支：origin/\(mergeBranch)…\n")
            let mergeResult = try run(
                executable: "/usr/bin/git",
                arguments: [
                    "-C", worktreeRoot.path,
                    "-c", "user.name=ZXAutoPackager", "-c", "user.email=zxautopackager@localhost",
                    "-c", "commit.gpgsign=false",
                    "merge", "--no-edit", "--no-ff", "refs/remotes/origin/\(mergeBranch)"
                ],
                cancellation: cancellation
            )
            guard !cancellation.isCancelled else { throw GitPreparationError.cancelled }
            guard mergeResult.status == 0 else {
                let conflicts = try run(
                    executable: "/usr/bin/git",
                    arguments: ["-C", worktreeRoot.path, "diff", "--name-only", "--diff-filter=U"]
                )
                if conflicts.status == 0 && !conflicts.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    prepared = true
                    throw GitMergeConflict(context: context, branch: mergeBranch, nextIndex: index + 1,
                                           files: conflicts.output.split(separator: "\n").map(String.init),
                                           output: mergeResult.output)
                }
                throw GitPreparationError.commandFailed(
                    "git merge origin/\(mergeBranch)", mergeResult.status, mergeResult.output
                )
            }
            onOutput("origin/\(mergeBranch) 合并完成（提交仅保存在临时 Worktree）。\n")
        }

        try installDependencies(in: context, enabled: installPods, cancellation: cancellation, onOutput: onOutput)
        guard !cancellation.isCancelled else { throw GitPreparationError.cancelled }
        prepared = true
        return context
    }

    private static func installDependencies(
        in context: GitWorktreeContext, enabled: Bool, cancellation: BuildCancellationController,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws {
        guard enabled else { return }
        let temporaryProjectURL = context.projectDirectory
        let podfileURL = temporaryProjectURL.appendingPathComponent("Podfile")
        guard FileManager.default.fileExists(atPath: podfileURL.path) else {
            throw GitPreparationError.podfileNotFound
        }

        let searchPaths = commandSearchPaths(existingPath: ProcessInfo.processInfo.environment["PATH"])
        guard let podExecutable = searchPaths
            .map({ URL(fileURLWithPath: $0).appendingPathComponent("pod").path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw GitPreparationError.commandFailed(
                "pod install",
                127,
                "未找到 CocoaPods。请确认终端可执行 pod，并检查路径：\n\(searchPaths.joined(separator: "\n"))"
            )
        }

        onOutput("===== 安装 CocoaPods 依赖 =====\n")
        onOutput("正在执行 \(podExecutable) install…\n")
        let podResult = try run(
            executable: podExecutable,
            arguments: ["install"],
            currentDirectory: temporaryProjectURL,
            cancellation: cancellation
        )
        guard !cancellation.isCancelled else { throw GitPreparationError.cancelled }
        guard podResult.status == 0 else {
            throw GitPreparationError.commandFailed("pod install", podResult.status, podResult.output)
        }
        onOutput("Pods 安装完成。\n")
    }

    static func continueMerge(
        conflict: GitMergeConflict, remainingBranches: [String], installPods: Bool,
        cancellation: BuildCancellationController, onOutput: @escaping @Sendable (String) -> Void
    ) throws -> GitWorktreeContext {
        let context = conflict.context
        let root = context.worktreeRoot
        guard !cancellation.isCancelled else { throw GitPreparationError.cancelled }
        let state = try run(executable: "/usr/bin/git", arguments: ["-C", root.path, "rev-parse", "-q", "--verify", "MERGE_HEAD"])
        guard state.status == 0 else { throw GitPreparationError.mergeNoLongerInProgress }
        let files = try unresolvedFiles(in: context)
        guard files.isEmpty else { throw GitPreparationError.unresolvedConflicts(files) }
        let commit = try run(executable: "/usr/bin/git", arguments: [
            "-C", root.path, "-c", "user.name=ZXAutoPackager", "-c", "user.email=zxautopackager@localhost",
            "-c", "commit.gpgsign=false", "-c", "core.editor=true", "merge", "--continue"
        ], cancellation: cancellation)
        guard !cancellation.isCancelled else { throw GitPreparationError.cancelled }
        guard commit.status == 0 else {
            throw GitPreparationError.commandFailed("git merge --continue", commit.status, commit.output)
        }
        onOutput("origin/\(conflict.branch) 的冲突已解决，合并继续。\n")
        for (offset, branch) in remainingBranches.enumerated() {
            guard !cancellation.isCancelled else { throw GitPreparationError.cancelled }
            onOutput("合并第 \(conflict.nextIndex + offset + 1) 个分支：origin/\(branch)…\n")
            let merge = try run(executable: "/usr/bin/git", arguments: [
                "-C", root.path, "-c", "user.name=ZXAutoPackager", "-c", "user.email=zxautopackager@localhost",
                "-c", "commit.gpgsign=false", "merge", "--no-edit", "--no-ff", "refs/remotes/origin/\(branch)"
            ], cancellation: cancellation)
            guard !cancellation.isCancelled else { throw GitPreparationError.cancelled }
            guard merge.status == 0 else {
                let files = try unresolvedFiles(in: context)
                if !files.isEmpty {
                    throw GitMergeConflict(context: context, branch: branch,
                                           nextIndex: conflict.nextIndex + offset + 1, files: files, output: merge.output)
                }
                throw GitPreparationError.commandFailed("git merge origin/\(branch)", merge.status, merge.output)
            }
            onOutput("origin/\(branch) 合并完成。\n")
        }
        try installDependencies(in: context, enabled: installPods, cancellation: cancellation, onOutput: onOutput)
        guard !cancellation.isCancelled else { throw GitPreparationError.cancelled }
        return context
    }

    static func unresolvedFiles(in context: GitWorktreeContext) throws -> [String] {
        let result = try run(executable: "/usr/bin/git", arguments: [
            "-C", context.worktreeRoot.path, "diff", "--name-only", "--diff-filter=U"
        ])
        guard result.status == 0 else {
            throw GitPreparationError.commandFailed("git diff --diff-filter=U", result.status, result.output)
        }
        return result.output.split(separator: "\n").map(String.init)
    }

    static func cleanup(_ context: GitWorktreeContext) {
        cleanup(repositoryRoot: context.repositoryRoot, worktreeRoot: context.worktreeRoot)
    }

    private static func repositoryRoot(for projectURL: URL) throws -> URL {
        let result = try run(
            executable: "/usr/bin/git",
            arguments: ["-C", projectURL.path, "rev-parse", "--show-toplevel"]
        )
        guard result.status == 0 else { throw GitPreparationError.invalidRepository }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw GitPreparationError.invalidRepository }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func relativePath(of child: URL, from parent: URL) -> String? {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        guard childPath == parentPath || childPath.hasPrefix(parentPath + "/") else { return nil }
        if childPath == parentPath { return "" }
        return String(childPath.dropFirst(parentPath.count + 1))
    }

    private static func cleanup(repositoryRoot: URL, worktreeRoot: URL) {
        guard FileManager.default.fileExists(atPath: worktreeRoot.path) else { return }
        _ = try? run(
            executable: "/usr/bin/git",
            arguments: [
                "-C", repositoryRoot.path,
                "worktree", "remove", "--force", worktreeRoot.path
            ]
        )
        try? FileManager.default.removeItem(at: worktreeRoot)
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private static func commandSearchPaths(existingPath: String?) -> [String] {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser.path
        var paths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/opt/ruby/bin",
            "/usr/local/bin",
            "/usr/local/opt/ruby/bin"
        ]

        for gemRoot in [
            "/opt/homebrew/lib/ruby/gems",
            "/usr/local/lib/ruby/gems",
            "\(homeDirectory)/.gem/ruby"
        ] {
            guard let versions = try? fileManager.contentsOfDirectory(atPath: gemRoot) else { continue }
            paths.append(contentsOf: versions.map { "\(gemRoot)/\($0)/bin" })
        }

        paths.append(contentsOf: [
            "\(homeDirectory)/.rbenv/shims",
            "\(homeDirectory)/.rvm/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ])
        if let existingPath {
            paths.append(contentsOf: existingPath.split(separator: ":").map(String.init))
        }

        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        cancellation: BuildCancellationController? = nil
    ) throws -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = pipe
        process.standardError = pipe

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = commandSearchPaths(existingPath: environment["PATH"])
            .joined(separator: ":")
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment

        try process.run()
        cancellation?.register(process)
        defer { cancellation?.clear(process) }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}
