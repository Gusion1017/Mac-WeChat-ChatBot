import Foundation

// MARK: - Resolution

/// 一次微信账号识别结果。
///
/// `accountID` 是微信账号（wxid），也就是 `accounts/<id>/` 的目录名；
/// `imageDirectory` 是该账号在微信容器里的媒体临时目录（`.../temp`，不存在时为 nil），
/// 启动 bridge 时作为 `-image_path`，让 bridge 能推导出与账号档案一致的 self_id。
struct WeChatAccountResolution: Equatable, Sendable {
    /// 识别依据：登录标记优先，账号目录活动时间兜底。
    enum Source: String, Equatable, Sendable {
        /// `app_data/login/<wxid>/key_info.dat` 或 `xwechat_files/all_users/login/<wxid>/key_info.db` 的 mtime。
        case loginMarker
        /// `xwechat_files/<wxid>_<suffix>/` 下 temp / db_storage 的最近活动时间。
        case accountActivity
    }

    var accountID: String
    var imageDirectory: URL?
    var source: Source
    var activityDate: Date?
}

// MARK: - Resolver

/// 识别微信客户端最近登录的账号。
///
/// 数据位置（macOS 微信 4.x 容器）：
/// ```
/// ~/Library/Containers/com.tencent.xinWeChat/Data/Documents/
/// ├── app_data/login/<wxid>/key_info.dat
/// └── xwechat_files/
///     ├── all_users/login/<wxid>/key_info.db (+ -wal)
///     └── <wxid>_<suffix>/{temp, db_storage/...}
/// ```
///
/// 优先级（见实施契约 §2.1）：
/// 1. 登录标记 mtime：`app_data/login/<wxid>/key_info.dat` 与
///    `xwechat_files/all_users/login/<wxid>/key_info.db`（含 `-wal`）取最大值。
///    只有登录标记、**但没有** `xwechat_files/<wxid>_<suffix>/` 数据目录的账号不算命中
///    （残留标记可能来自已删除/迁移的账号）。
/// 2. 回退到数据目录活动时间：目录自身、`temp/`、`db_storage/session/session.db`、
///    `db_storage/message/message_0.db` 的 mtime 最大值；等价于旧
///    `AppResources.imageDirectory()` 的启发式，但额外返回账号 ID。
/// 3. 都没有 → nil。多个账号活动时间相同时按账号 ID 字典序稳定取第一个。
///
/// 目录/文件缺失、隐藏目录、`all_users` / `Backup` 等非账号目录、非法账号名
/// 一律安全跳过；不会抛出、不会修改任何文件。
struct WeChatAccountResolver: Sendable {
    /// 微信容器 `Documents` 根目录。默认按当前用户的真实容器准备，测试可注入临时目录。
    static var defaultDocumentsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.tencent.xinWeChat/Data/Documents",
                isDirectory: true
            )
    }

    /// 微信容器 `Documents` 根目录（`xwechat_files/` 与 `app_data/` 的父目录）。
    let documentsRoot: URL

    init(documentsRoot: URL = Self.defaultDocumentsRoot) {
        self.documentsRoot = documentsRoot
    }

    /// 最近登录且仍有 `xwechat_files` 数据目录的账号；识别不到返回 nil。
    func resolve() -> WeChatAccountResolution? {
        let accounts = dataAccounts()
        guard !accounts.isEmpty else { return nil }

        // 1) 登录标记优先。accounts 已按账号 ID 字典序排序，严格大于比较保证同时间稳定取字典序最小。
        var loginBest: (account: DataAccount, date: Date)?
        for account in accounts {
            guard let date = loginMarkerDate(forAccountID: account.id) else { continue }
            if loginBest == nil || date > loginBest!.date {
                loginBest = (account, date)
            }
        }
        if let loginBest {
            return WeChatAccountResolution(
                accountID: loginBest.account.id,
                imageDirectory: imageDirectory(in: loginBest.account.directory),
                source: .loginMarker,
                activityDate: loginBest.date
            )
        }

        // 2) 回退：数据目录活动时间。
        var activityBest: DataAccount?
        for account in accounts {
            if activityBest == nil || account.activity > activityBest!.activity {
                activityBest = account
            }
        }
        guard let activityBest else { return nil }
        return WeChatAccountResolution(
            accountID: activityBest.id,
            imageDirectory: imageDirectory(in: activityBest.directory),
            source: .accountActivity,
            activityDate: activityBest.activity
        )
    }

    /// 指定账号在微信容器里的媒体临时目录（`xwechat_files/<dir>/temp`，不存在时 nil）。
    ///
    /// 只按 `<wxid>_<suffix>` 数据目录名匹配；`wxid` 本身不含后缀，因此不会因为
    /// 多个账号目录同时存在而选错（旧实现按字典序取第一个，见 AppResources.imageDirectory）。
    func imageDirectory(forAccountID id: String) -> URL? {
        guard AppAccount.isValidID(id) else { return nil }
        guard let account = dataAccounts().first(where: { $0.id == id }) else { return nil }
        return imageDirectory(in: account.directory)
    }

    // MARK: - Data directories

    private struct DataAccount {
        let id: String
        let name: String
        let directory: URL
        let activity: Date
    }

    /// 非微信账号的保留目录名（小写比较）。
    private static let reservedDirectoryNames: Set<String> = [
        "all_users",
        "app_data",
        "appdata",
        "backup",
    ]

    /// 扫描 `xwechat_files/` 下形如 `<wxid>_<suffix>/` 的数据目录，按账号 ID 稳定排序。
    /// 同一个账号 ID 出现多个目录时保留活动时间较新的一个（时间相同取目录名字典序小者）。
    private func dataAccounts() -> [DataAccount] {
        let fileManager = FileManager.default
        let root = documentsRoot.appendingPathComponent("xwechat_files", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var byID: [String: DataAccount] = [:]
        for entry in entries {
            let name = entry.lastPathComponent
            guard let id = Self.accountID(fromDataDirectoryName: name) else { continue }
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            let account = DataAccount(
                id: id,
                name: name,
                directory: entry,
                activity: Self.directoryActivity(entry)
            )
            if let existing = byID[id] {
                if account.activity > existing.activity
                    || (account.activity == existing.activity && account.name < existing.name) {
                    byID[id] = account
                }
            } else {
                byID[id] = account
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// `<wxid>_<suffix>` → `wxid`；隐藏/保留名、非法字符、缺少后缀的目录返回 nil。
    ///
    /// 后缀只取最后一个下划线之后的部分：账号 ID 本身可能含下划线（`wxid_abc_def`）。
    /// 后缀要求为 1...16 个 ASCII 字母数字，用于排除 `<id>_abcd.bak` 之类的备份目录。
    private static func accountID(fromDataDirectoryName name: String) -> String? {
        guard !name.hasPrefix(".") else { return nil }
        let lowered = name.lowercased()
        guard !reservedDirectoryNames.contains(lowered) else { return nil }
        guard let separator = name.lastIndex(of: "_") else { return nil }

        let id = String(name[name.startIndex..<separator])
        let suffix = String(name[name.index(after: separator)...])
        guard !id.isEmpty, !suffix.isEmpty, suffix.count <= 16 else { return nil }
        guard suffix.allSatisfy(\.isASCIIAlphaNumeric) else { return nil }
        guard AppAccount.isValidID(id) else { return nil }
        return id
    }

    /// 数据目录的最近活动时间：目录自身 / `temp/` / `db_storage/` /
    /// session 与 message 主库的 mtime 最大值。
    private static func directoryActivity(_ directory: URL) -> Date {
        let candidates = [
            directory,
            directory.appendingPathComponent("temp", isDirectory: true),
            directory.appendingPathComponent("db_storage", isDirectory: true),
            directory.appendingPathComponent("db_storage/session/session.db"),
            directory.appendingPathComponent("db_storage/message/message_0.db"),
        ]
        var latest = Date.distantPast
        for candidate in candidates {
            if let date = modificationDate(candidate), date > latest {
                latest = date
            }
        }
        return latest
    }

    private func imageDirectory(in accountDirectory: URL) -> URL? {
        let temp = accountDirectory.appendingPathComponent("temp", isDirectory: true)
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: temp.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return temp
    }

    // MARK: - Login markers

    /// 账号最近登录标记的 mtime：`app_data/login/<id>/key_info.dat` 与
    /// `xwechat_files/all_users/login/<id>/key_info.db`（含 `-wal`）取最大值。
    private func loginMarkerDate(forAccountID id: String) -> Date? {
        var dates: [Date] = []

        let keyInfoDat = documentsRoot.appendingPathComponent("app_data/login/\(id)/key_info.dat")
        if let date = Self.modificationDate(keyInfoDat) {
            dates.append(date)
        }

        let allUsersKeyInfoDB = documentsRoot
            .appendingPathComponent("xwechat_files/all_users/login/\(id)/key_info.db")
        if let date = Self.modificationDate(allUsersKeyInfoDB) {
            dates.append(date)
        }
        // SQLite WAL 的写入时间通常比主库更接近“最后一次登录”。
        if let date = Self.modificationDate(URL(fileURLWithPath: allUsersKeyInfoDB.path + "-wal")) {
            dates.append(date)
        }

        return dates.max()
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// MARK: - Account IDs

/// 账号目录命名规则与展示脱敏。
///
/// 账号 ID 直接作为 `accounts/<id>/` 目录名，所以校验必须严格拒绝路径穿越；
/// `_unassigned` 是“尚未识别微信账号”的保留档案名，不能作为真实账号 ID。
enum AppAccount {
    /// 尚未识别微信账号时的临时档案目录名（保留名，不是合法账号 ID）。
    static let unassignedID = "_unassigned"

    /// `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`（1...64 个字符，首字符字母/数字）。
    static func isValidID(_ raw: String) -> Bool {
        guard (1...64).contains(raw.count) else { return false }
        guard let first = raw.unicodeScalars.first, Self.isASCIIAlphaNumeric(first) else { return false }
        return raw.unicodeScalars.dropFirst().allSatisfy {
            Self.isASCIIAlphaNumeric($0) || $0 == "_" || $0 == "-"
        }
    }

    /// UI 展示用的脱敏账号：未识别 → `未识别`；≤ 10 字符原样；更长 → 前 9 + `…` + 后 4。
    static func maskedID(_ id: String) -> String {
        if id == unassignedID { return "未识别" }
        guard id.count > 10 else { return id }
        return String(id.prefix(9)) + "…" + String(id.suffix(4))
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }
}

private extension Character {
    /// ASCII 字母数字（用于 `xwechat_files/<wxid>_<suffix>` 的后缀校验）。
    var isASCIIAlphaNumeric: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
            default: return false
            }
        }
    }
}
