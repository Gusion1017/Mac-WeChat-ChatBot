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

    /// 把仓库里的版本 JSON 与运行期覆盖项（例如 4.1.15.55 的 R3 发送开关）合并，
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
    /// `.../xwechat_files/<account>/temp/`, so any existing account temp dir works.
    static func imageDirectory() -> URL? {
        let containers = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files",
                                    isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: containers,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let temp = entry.appendingPathComponent("temp", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: temp.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return temp
            }
        }
        return nil
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
        add(URL(fileURLWithPath: #filePath).deletingLastPathComponent(), ancestors: 8)
        return roots
    }
}
