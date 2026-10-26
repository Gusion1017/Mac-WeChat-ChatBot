import Foundation

// MARK: - Status

/// Xcode Command Line Tools（CLT）检测结果。
///
/// Hook 安装与状态检测依赖 `/usr/bin/python3` 与 `/usr/bin/otool`。这两个是
/// `xcode-select` 的 tool shim（`com.apple.dt.xcode_select.tool-shim-public`），
/// 只有安装 Xcode 或 Command Line Tools 后才可用；直接执行 shim 会触发系统的
/// “安装命令行开发者工具”弹窗。因此检测只使用真实系统工具
/// `/usr/bin/xcode-select` 与 `/usr/bin/xcrun`，并且只对 `xcrun` 解析出的真实
/// 路径执行 `--version`。
struct CommandLineToolsStatus: Sendable, Equatable {
    var developerDirectory: String?
    var python3Path: String?
    var otoolPath: String?
    var pythonVersion: String?
    var isReady: Bool
}

// MARK: - Detection

enum CommandLineTools {
    /// 真实系统工具；即使 CLT 未安装也存在，可用于无弹窗检测。
    static let xcodeSelectPath = "/usr/bin/xcode-select"
    static let xcrunPath = "/usr/bin/xcrun"

    /// 检测当前运行环境是否已具备 Hook 所需的 CLT 工具链。
    ///
    /// 三个探测命令各自带超时；任何一步失败都不会崩溃，只会让对应字段为 nil。
    static func status() async -> CommandLineToolsStatus {
        let developer = await developerDirectory()
        let pythonPath = await resolvedToolPath("python3")
        let otoolPath = await resolvedToolPath("otool")
        var version: String?
        if let pythonPath {
            version = await pythonVersion(at: pythonPath)
        }
        return classify(
            developerDirectory: developer,
            python3Path: pythonPath,
            otoolPath: otoolPath,
            pythonVersion: version
        )
    }

    /// 纯函数：根据原始检测结果推导状态，供单元测试直接覆盖。
    ///
    /// - `isReady` 要求 python3 与 otool 均解析到**可执行**的真实路径。
    /// - 空字符串等同于 nil；不可执行的路径会被过滤掉，避免 UI 展示假路径。
    static func classify(
        developerDirectory: String?,
        python3Path: String?,
        otoolPath: String?,
        pythonVersion: String?
    ) -> CommandLineToolsStatus {
        let developer = normalizedDirectory(developerDirectory)
        let python = executablePath(python3Path)
        let otool = executablePath(otoolPath)
        return CommandLineToolsStatus(
            developerDirectory: developer,
            python3Path: python,
            otoolPath: otool,
            pythonVersion: normalizedVersion(pythonVersion),
            isReady: python != nil && otool != nil
        )
    }

    /// `/usr/bin/xcode-select -p`：当前 developer directory。
    static func developerDirectory() async -> String? {
        guard case .finished(let result) = await run(xcodeSelectPath, ["-p"], timeout: .seconds(5)),
              result.status == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// `/usr/bin/xcrun --find <tool>`：解析 shim 背后的真实工具路径。
    ///
    /// 注意全量 Xcode 环境下 otool 位于 Toolchains 内，而不是
    /// `<developerDirectory>/usr/bin/otool`，因此必须由 xcrun 解析。
    static func resolvedToolPath(_ tool: String) async -> String? {
        guard case .finished(let result) = await run(xcrunPath, ["--find", tool], timeout: .seconds(8)),
              result.status == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// 对 xcrun 解析出的真实 python3 执行 `--version`（不是 /usr/bin/python3 shim）。
    static func pythonVersion(at path: String) async -> String? {
        guard case .finished(let result) = await run(path, ["--version"], timeout: .seconds(5)),
              result.status == 0 else { return nil }
        let output = result.stdout + "\n" + result.stderr
        guard let range = output.range(of: "Python ") else { return nil }
        let version = output[range.upperBound...].prefix { character in
            character.isNumber || character == "."
        }
        let trimmed = String(version).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 打开系统自带的 CLT 安装向导（只弹窗，不自行 sudo / 不静默安装）。
    ///
    /// 非 0 退出码按 stderr 归纳成可行动的中文提示；调用方负责重新检测。
    static func requestInstall() async -> (ok: Bool, message: String?) {
        switch await run(xcodeSelectPath, ["--install"], timeout: .seconds(30)) {
        case .finished(let result):
            guard result.status != 0 else { return (true, nil) }
            return (false, installFailureMessage(for: result))
        case .timedOut, .failed:
            return (false, "无法打开 Command Line Tools 安装窗口，请在终端运行 xcode-select --install。")
        }
    }

    // MARK: Helpers

    private static func installFailureMessage(for result: ProcessResult) -> String {
        let output = (result.stderr + "\n" + result.stdout).lowercased()
        if output.contains("already installed") {
            return "Command Line Tools 已安装，请点「重新检测」。"
        }
        if output.contains("administrator") || output.contains("permission")
            || output.contains("not allowed") || output.contains("root") {
            return "需要管理员授权，请在终端运行 xcode-select --install。"
        }
        return "无法打开 Command Line Tools 安装窗口，请在终端运行 xcode-select --install。"
    }

    private static func normalizedDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func executablePath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return FileManager.default.isExecutableFile(atPath: trimmed) ? trimmed : nil
    }

    private static func normalizedVersion(_ version: String?) -> String? {
        guard let version else { return nil }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Process execution with timeout

extension CommandLineTools {
    fileprivate enum RunOutcome: Sendable {
        case finished(ProcessResult)
        case failed
        case timedOut
    }

    /// 启动短命令并在超时后终止子进程。所有探测命令都不会阻塞主线程。
    fileprivate static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: Duration
    ) async -> RunOutcome {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return .failed }
        let handle = ProcessRunner.launch(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments
        )

        return await withTaskGroup(of: RunOutcome.self) { group in
            group.addTask {
                var stdout = ""
                var stderr = ""
                var status: Int32 = -1
                do {
                    for try await event in handle.events {
                        switch event {
                        case .line(let line, .stdout):
                            stdout += line + "\n"
                        case .line(let line, .stderr):
                            stderr += line + "\n"
                        case .terminated(let code):
                            status = code
                        }
                    }
                } catch {
                    return .failed
                }
                return .finished(ProcessResult(status: status, stdout: stdout, stderr: stderr))
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }

            guard let first = await group.next() else { return .failed }
            if case .timedOut = first, handle.process.isRunning {
                handle.process.terminate()
            }
            group.cancelAll()
            await group.waitForAll()
            return first
        }
    }
}
