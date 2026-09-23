import Foundation

struct GitWorktreeContext: Sendable {
    let repositoryRoot: URL
    let worktreeRoot: URL
    let projectDirectory: URL
}

enum GitPreparationError: LocalizedError {
    case commandFailed(String, Int32, String)
    case invalidRepository
    case invalidProjectPath
    case noRemoteBranches
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
            cleanup(repositoryRoot: root, worktreeRoot: worktreeRoot)
            throw GitPreparationError.cancelled
        }
        guard worktreeResult.status == 0 else {
            cleanup(repositoryRoot: root, worktreeRoot: worktreeRoot)
            throw GitPreparationError.commandFailed(
                "git worktree add --detach origin/\(branch)",
                worktreeResult.status,
                worktreeResult.output
            )
        }

        let temporaryProjectURL = relativeProjectPath.isEmpty
            ? worktreeRoot
            : worktreeRoot.appendingPathComponent(relativeProjectPath, isDirectory: true)

        if installPods {
            let podfileURL = temporaryProjectURL.appendingPathComponent("Podfile")
            guard FileManager.default.fileExists(atPath: podfileURL.path) else {
                cleanup(repositoryRoot: root, worktreeRoot: worktreeRoot)
                throw GitPreparationError.podfileNotFound
            }

            onOutput("===== 安装 CocoaPods 依赖 =====\n")
            onOutput("正在执行 pod install…\n")
            let podResult = try run(
                executable: "/usr/bin/env",
                arguments: ["pod", "install"],
                currentDirectory: temporaryProjectURL,
                cancellation: cancellation
            )
            guard !cancellation.isCancelled else {
                cleanup(repositoryRoot: root, worktreeRoot: worktreeRoot)
                throw GitPreparationError.cancelled
            }
            guard podResult.status == 0 else {
                cleanup(repositoryRoot: root, worktreeRoot: worktreeRoot)
                throw GitPreparationError.commandFailed("pod install", podResult.status, podResult.output)
            }
            onOutput("Pods 安装完成。\n")
        }

        return GitWorktreeContext(
            repositoryRoot: root,
            worktreeRoot: worktreeRoot,
            projectDirectory: temporaryProjectURL
        )
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
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            environment["PATH"] ?? ""
        ].joined(separator: ":")
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
