import Foundation

/// Resolves app resources both from the packaged `.app` bundle and the SPM dev tree.
///
/// Packaged layout (build_app.sh):
/// ```
/// Contents/Resources/bridge/onebot, bridge/script.js
/// Contents/Resources/hook/versions/*.json
/// Contents/Resources/hook/gadget/FridaGadget.dylib
/// Contents/Resources/tools/install_gadget.sh
/// ```
///
/// Resolution order (per Lead):
/// 1. `Bundle.main.resourceURL`
/// 2. `WECHATAI_ROOT`
/// 3. ancestors of the bundle / executable / working directory (`swift run` dev tree)
/// 4. ancestors of this source file (last-resort dev fallback)
///
/// Returns `nil` instead of crashing so callers can show a clear error.
enum AppResources {
    static var root: URL? {
        for candidate in candidateRoots() {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("bridge/onebot").path)
                || fileManager.fileExists(atPath: candidate.appendingPathComponent("tools/install_gadget.sh").path)
                || fileManager.fileExists(atPath: candidate.appendingPathComponent("bridge/script.js").path) {
                return candidate
            }
        }
        return nil
    }

    static var bridgeDirectory: URL? {
        guard let root else { return nil }
        let directory = root.appendingPathComponent("bridge", isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    static var bridgeBinary: URL? {
        guard let directory = bridgeDirectory else { return nil }
        let binary = directory.appendingPathComponent("onebot")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        return binary
    }

    /// 旧版 bridge 的日志写在 `Contents/Resources/bridge/log/macos.log`，
    /// 这会在 ad-hoc 签名的 bundle 里多出一个未封存的文件，导致下次启动被
    /// macOS 以 `Launch Constraint Violation` 杀掉。新版日志已外置到
    /// `AppPaths.bridgeLogDirectory`；这里启动时顺手清掉历史残留（自愈）。
    @discardableResult
    static func removeLegacyBridgeLog() -> Bool {
        guard let bridgeDirectory else { return false }
        let legacy = bridgeDirectory.appendingPathComponent("log", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return false }
        do {
            try FileManager.default.removeItem(at: legacy)
            return true
        } catch {
            return false
        }
    }

    static var hookDirectory: URL? {
        guard let root else { return nil }
        let directory = root.appendingPathComponent("hook", isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    static var versionConfigDirectory: URL? {
        guard let hookDirectory else { return nil }
        let directory = hookDirectory.appendingPathComponent("versions", isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    static func normalizedVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.replacingOccurrences(of: ".", with: "_")
    }

    /// `hook/versions/<version_with_underscores>_mac.json`, honouring an explicit path first.
    static func versionConfig(version: String, explicitPath: String = "") -> URL? {
        if !explicitPath.isEmpty {
            let expanded = (explicitPath as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                // 仓库自带的版本文件必须匹配当前微信版本；否则（例如用户之前持久化了
                // 4_1_12_53 的路径后升级微信）静默忽略，回退到自动匹配。
                let isBundled = versionConfigDirectory.map { expanded.hasPrefix($0.path) } ?? false
                let expectedName = "\(normalizedVersion(version))_mac.json"
                if !isBundled || URL(fileURLWithPath: expanded).lastPathComponent == expectedName {
                    return URL(fileURLWithPath: expanded)
                }
            }
        }
        guard let directory = versionConfigDirectory, !version.isEmpty else { return nil }
        let filename = "\(normalizedVersion(version))_mac.json"
        let url = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 把仓库里的版本 JSON 与运行期覆盖项（例如 4.1.15.55 / 4.2.0.x 的 R3 发送开关）合并，
    /// 写入 `Application Support/WeChatAI/runtime/`，返回给 bridge 使用的路径。
    /// 仓库 JSON 保持默认 off，产品行为完全由 App 设置决定。
    static func materializedVersionConfig(
        version: String,
        build: String = "",
        explicitPath: String = "",
        overrides: [String: String] = [:],
        outputDirectory: URL = AppPaths.runtimeDirectory
    ) -> URL? {
        guard let baseURL = versionConfig(version: version, explicitPath: explicitPath) else { return nil }
        guard !overrides.isEmpty else { return baseURL }

        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: baseURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        } else {
            return nil
        }
        for (key, value) in overrides { object[key] = value }

        let directory = outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeVersion = version.replacingOccurrences(of: "/", with: "_")
        let safeBuild = build.isEmpty ? "0" : build
        let url = directory.appendingPathComponent("hook-\(safeVersion)-\(safeBuild).json")
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func expectedVersionConfigPath(version: String, explicitPath: String = "") -> String {
        if !explicitPath.isEmpty { return (explicitPath as NSString).expandingTildeInPath }
        guard let directory = versionConfigDirectory, !version.isEmpty else {
            return "hook/versions/<version>_mac.json"
        }
        return directory.appendingPathComponent("\(normalizedVersion(version))_mac.json").path
    }

    static var gadgetDylib: URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent("hook/gadget/FridaGadget.dylib")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var gadgetConfig: URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent("hook/gadget/FridaGadget.config")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var installScript: URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent("tools/install_gadget.sh")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var manageScript: URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent("tools/manage_wechat.sh")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var injectorScript: URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent("tools/inject_load_dylib.py")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// WeChat's media temp directory. The upstream bridge derives the wxid from
    /// `.../xwechat_files/<account>/temp/`.
    ///
    /// 一台 Mac 上可能同时存在多个账号目录（例如主号和机器人号都登录过）。
    /// 旧实现按目录名字典序取第一个，常把 image_path 指到**非当前登录**的账号，
    /// 进而让 bridge 推导出错误的 myWechatId（影响自消息方向/发送 proto）。
    /// 现在改为取最近有活动的账号：优先看 session/message 库与 temp 的 mtime。
    static func imageDirectory() -> URL? {
        let containers = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files",
                                    isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: containers,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        func mtime(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
        }

        var best: (temp: URL, activity: Date)?
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let temp = entry.appendingPathComponent("temp", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: temp.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let activity = max(
                max(mtime(entry), mtime(temp)),
                max(
                    mtime(entry.appendingPathComponent("db_storage/session/session.db")),
                    mtime(entry.appendingPathComponent("db_storage/message/message_0.db"))
                )
            )
            if best == nil || activity > best!.activity {
                best = (temp, activity)
            }
        }
        // 只返回目录；账号身份由 App 通过 -self_id 传给 bridge（见 HookManager）。
        return best?.temp
    }

    static func candidateRoots() -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL, ancestors: Int) {
            var current = url
            var remaining = ancestors
            while true {
                let standardized = current.standardizedFileURL
                if seen.insert(standardized.path).inserted { roots.append(standardized) }
                if remaining == 0 { break }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
                remaining -= 1
            }
        }

        if let resources = Bundle.main.resourceURL { add(resources, ancestors: 0) }
        if let env = ProcessInfo.processInfo.environment["WECHATAI_ROOT"], !env.isEmpty {
            add(URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true), ancestors: 0)
        }
        add(Bundle.main.bundleURL, ancestors: 8)
        add(URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent(), ancestors: 8)
        add(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true), ancestors: 8)
        // 不要使用 #filePath：Swift 会把编译机的绝对路径嵌入二进制，泄露本地用户名/目录。
        // Bundle、进程参数与当前目录已覆盖打包运行与源码运行两种入口。
        return roots
    }
}
