import Foundation
import XCTest
@testable import WeChatAI

/// `WeChatAccountResolver` / `AppAccount` 单测。
///
/// 全部使用 temporaryDirectory 注入的假微信容器；夹具里的 wxid 均为占位符，
/// 不触碰真实微信目录，也不包含任何真实账号/聊天数据。
final class WeChatAccountResolverTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryRoot: URL!

    /// 固定基准时间，避免测试依赖当前时间/文件系统时间精度。
    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUpWithError() throws {
        temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("wechatai-account-resolver-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? fileManager.removeItem(at: temporaryRoot)
        }
    }

    // MARK: - Fixtures

    private var documentsRoot: URL {
        temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
    }

    private var xwechatFiles: URL {
        documentsRoot.appendingPathComponent("xwechat_files", isDirectory: true)
    }

    private func setModificationDate(_ url: URL, _ date: Date) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @discardableResult
    private func makeDataAccount(
        id: String,
        suffix: String = "abcd",
        activity: Date,
        hasTemp: Bool = true,
        sessionDatabaseActivity: Date? = nil
    ) throws -> URL {
        let directory = xwechatFiles.appendingPathComponent("\(id)_\(suffix)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if hasTemp {
            let temp = directory.appendingPathComponent("temp", isDirectory: true)
            try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
            try setModificationDate(temp, activity)
        }
        if let sessionDatabaseActivity {
            let database = directory.appendingPathComponent("db_storage/session/session.db")
            try fileManager.createDirectory(
                at: database.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: database)
            try setModificationDate(database, sessionDatabaseActivity)
        }
        // 最后设置目录自身 mtime：创建子目录/文件会刷新父目录 mtime。
        try setModificationDate(directory, activity)
        return directory
    }

    private func writeAppDataLoginMarker(_ id: String, date: Date) throws {
        let url = documentsRoot.appendingPathComponent("app_data/login/\(id)/key_info.dat")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: url)
        try setModificationDate(url, date)
    }

    private func writeAllUsersLoginMarker(_ id: String, databaseDate: Date, walDate: Date? = nil) throws {
        let database = documentsRoot.appendingPathComponent("xwechat_files/all_users/login/\(id)/key_info.db")
        try fileManager.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("marker".utf8).write(to: database)
        try setModificationDate(database, databaseDate)
        if let walDate {
            let wal = URL(fileURLWithPath: database.path + "-wal")
            try Data("marker".utf8).write(to: wal)
            try setModificationDate(wal, walDate)
        }
    }

    private func resolver() -> WeChatAccountResolver {
        WeChatAccountResolver(documentsRoot: documentsRoot)
    }

    // MARK: - 识别优先级

    func testLoginMarkerWinsEvenWhenAnotherAccountHasNewerActivity() throws {
        // alpha 的登录标记较旧，beta 的数据目录活动更新；登录标记优先级更高。
        try makeDataAccount(id: "wxid_alpha_test", activity: base)
        try makeDataAccount(id: "wxid_beta_test", activity: base.addingTimeInterval(3_600))
        try writeAppDataLoginMarker("wxid_alpha_test", date: base)

        let resolution = try XCTUnwrap(resolver().resolve())
        XCTAssertEqual(resolution.accountID, "wxid_alpha_test")
        XCTAssertEqual(resolution.source, .loginMarker)
        XCTAssertEqual(resolution.activityDate, base)
        XCTAssertEqual(resolution.imageDirectory?.lastPathComponent, "temp")
        XCTAssertTrue(resolution.imageDirectory?.path.contains("wxid_alpha_test_abcd") == true)
    }

    func testAccountActivityFallbackPicksMostRecentDirectory() throws {
        try makeDataAccount(id: "wxid_alpha_test", activity: base)
        try makeDataAccount(id: "wxid_beta_test", activity: base.addingTimeInterval(600))

        let resolution = try XCTUnwrap(resolver().resolve())
        XCTAssertEqual(resolution.accountID, "wxid_beta_test")
        XCTAssertEqual(resolution.source, .accountActivity)
        XCTAssertEqual(resolution.activityDate, base.addingTimeInterval(600))
        XCTAssertTrue(resolution.imageDirectory?.path.contains("wxid_beta_test_abcd") == true)
    }

    func testAllUsersKeyInfoDatabaseAndWALCountAsLoginMarkers() throws {
        try makeDataAccount(id: "wxid_gamma_test", activity: base)
        let walDate = base.addingTimeInterval(900)
        try writeAllUsersLoginMarker("wxid_gamma_test", databaseDate: base, walDate: walDate)

        let resolution = try XCTUnwrap(resolver().resolve())
        XCTAssertEqual(resolution.accountID, "wxid_gamma_test")
        XCTAssertEqual(resolution.source, .loginMarker)
        XCTAssertEqual(resolution.activityDate?.timeIntervalSince1970 ?? 0, walDate.timeIntervalSince1970, accuracy: 0.5)
    }

    func testLoginMarkerDateUsesMaxOfAppDataAndAllUsers() throws {
        try makeDataAccount(id: "wxid_delta_test", activity: base)
        try writeAppDataLoginMarker("wxid_delta_test", date: base)
        let allUsersDate = base.addingTimeInterval(1_800)
        try writeAllUsersLoginMarker("wxid_delta_test", databaseDate: allUsersDate)

        let resolution = try XCTUnwrap(resolver().resolve())
        XCTAssertEqual(resolution.activityDate?.timeIntervalSince1970 ?? 0, allUsersDate.timeIntervalSince1970, accuracy: 0.5)
    }

    func testLoginMarkerWithoutDataDirectoryIsIgnored() throws {
        // 残留登录标记指向已删除/迁移的账号：不应被识别，回退到有数据目录的账号。
        try writeAppDataLoginMarker("wxid_ghost_test", date: base.addingTimeInterval(7_200))
        try makeDataAccount(id: "wxid_real_test", activity: base)

        let resolution = try XCTUnwrap(resolver().resolve())
        XCTAssertEqual(resolution.accountID, "wxid_real_test")
        XCTAssertEqual(resolution.source, .accountActivity)
    }

    // MARK: - 异常目录/缺失

    func testMissingOrEmptyDocumentsRootReturnsNil() throws {
        let missing = WeChatAccountResolver(
            documentsRoot: temporaryRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        )
        XCTAssertNil(missing.resolve())
        XCTAssertNil(missing.imageDirectory(forAccountID: "wxid_any_test"))

        try fileManager.createDirectory(at: xwechatFiles, withIntermediateDirectories: true)
        XCTAssertNil(resolver().resolve())
    }

    func testMalformedDirectoriesAreSafelyIgnored() throws {
        let recent = base.addingTimeInterval(86_400)
        // 隐藏目录、保留目录、无后缀、非法 ID、非法后缀都不得被当作账号。
        try fileManager.createDirectory(
            at: xwechatFiles.appendingPathComponent("all_users", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: xwechatFiles.appendingPathComponent("app_data", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: xwechatFiles.appendingPathComponent("Backup", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: xwechatFiles.appendingPathComponent(".hidden_account", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: xwechatFiles.appendingPathComponent("wxid_bad_suffix_ab@d", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: xwechatFiles.appendingPathComponent("bad id_abcd", isDirectory: true),
            withIntermediateDirectories: true
        )
        for name in ["all_users", "app_data", "Backup", ".hidden_account", "wxid_bad_suffix_ab@d", "bad id_abcd"] {
            try setModificationDate(xwechatFiles.appendingPathComponent(name), recent)
        }
        try makeDataAccount(id: "wxid_valid_test", activity: base)

        let resolution = try XCTUnwrap(resolver().resolve())
        XCTAssertEqual(resolution.accountID, "wxid_valid_test")
        XCTAssertEqual(resolution.source, .accountActivity)
    }

    func testAccountWithoutTempDirectoryHasNoImageDirectory() throws {
        try makeDataAccount(id: "wxid_notemp_test", activity: base, hasTemp: false)

        let resolution = try XCTUnwrap(resolver().resolve())
        XCTAssertEqual(resolution.accountID, "wxid_notemp_test")
        XCTAssertNil(resolution.imageDirectory)
        XCTAssertNil(resolver().imageDirectory(forAccountID: "wxid_notemp_test"))
    }

    // MARK: - 活动时间细节

    func testAccountActivityIncludesSessionDatabase() throws {
        // alpha 的 temp 较旧；beta 没有 temp，但 session.db 新 → beta 更近。
        try makeDataAccount(id: "wxid_alpha_test", activity: base)
        try makeDataAccount(
            id: "wxid_beta_test",
            activity: base,
            hasTemp: false,
            sessionDatabaseActivity: base.addingTimeInterval(1_200)
        )

        let resolution = try XCTUnwrap(resolver().resolve())
        XCTAssertEqual(resolution.accountID, "wxid_beta_test")
        XCTAssertEqual(resolution.source, .accountActivity)
        XCTAssertNil(resolution.imageDirectory)
    }

    func testTieBreakUsesLexicographicAccountID() throws {
        let sameMoment = base.addingTimeInterval(300)
        try makeDataAccount(id: "wxid_bbb_test", activity: sameMoment)
        try makeDataAccount(id: "wxid_aaa_test", activity: sameMoment)

        let resolution = try XCTUnwrap(resolver().resolve())
        XCTAssertEqual(resolution.accountID, "wxid_aaa_test")
        XCTAssertEqual(resolution.source, .accountActivity)
    }

    func testDuplicateAccountDirectoriesPreferMostRecentActivity() throws {
        try makeDataAccount(id: "wxid_dup_test", suffix: "aaaa", activity: base)
        try makeDataAccount(id: "wxid_dup_test", suffix: "bbbb", activity: base.addingTimeInterval(500))

        let resolution = try XCTUnwrap(resolver().resolve())
        XCTAssertEqual(resolution.accountID, "wxid_dup_test")
        XCTAssertTrue(resolution.imageDirectory?.path.contains("wxid_dup_test_bbbb") == true)
    }

    // MARK: - imageDirectory(forAccountID:)

    func testImageDirectoryForAccountIDDoesNotDependOnRecency() throws {
        let alpha = try makeDataAccount(id: "wxid_alpha_test", activity: base)
        try makeDataAccount(id: "wxid_beta_test", activity: base.addingTimeInterval(9_999))

        // macOS 的 /var 是 /private/var 的符号链接，FileManager 列举出的 URL 会解析成后者。
        XCTAssertEqual(
            resolver().imageDirectory(forAccountID: "wxid_alpha_test")?.resolvingSymlinksInPath().path,
            alpha.appendingPathComponent("temp", isDirectory: true).resolvingSymlinksInPath().path
        )
        XCTAssertNil(resolver().imageDirectory(forAccountID: "wxid_unknown_test"))
        XCTAssertNil(resolver().imageDirectory(forAccountID: "../etc"))
        XCTAssertNil(resolver().imageDirectory(forAccountID: AppAccount.unassignedID))
    }

    // MARK: - AppAccount

    func testAppAccountIDValidation() {
        XCTAssertTrue(AppAccount.isValidID("a"))
        XCTAssertTrue(AppAccount.isValidID("wxid_abc123"))
        XCTAssertTrue(AppAccount.isValidID("wxid_abc-def_123"))
        XCTAssertTrue(AppAccount.isValidID(String(repeating: "a", count: 64)))

        XCTAssertFalse(AppAccount.isValidID(""))
        XCTAssertFalse(AppAccount.isValidID("_unassigned"))
        XCTAssertFalse(AppAccount.isValidID("_leading"))
        XCTAssertFalse(AppAccount.isValidID("-leading"))
        XCTAssertFalse(AppAccount.isValidID("with space"))
        XCTAssertFalse(AppAccount.isValidID("path/traversal"))
        XCTAssertFalse(AppAccount.isValidID("path\\traversal"))
        XCTAssertFalse(AppAccount.isValidID("../evil"))
        XCTAssertFalse(AppAccount.isValidID("微信账号"))
        XCTAssertFalse(AppAccount.isValidID(String(repeating: "a", count: 65)))
    }

    func testMaskedID() {
        XCTAssertEqual(AppAccount.unassignedID, "_unassigned")
        XCTAssertEqual(AppAccount.maskedID(AppAccount.unassignedID), "未识别")
        XCTAssertEqual(AppAccount.maskedID("short"), "short")
        XCTAssertEqual(AppAccount.maskedID("abcdefghij"), "abcdefghij")
        XCTAssertEqual(AppAccount.maskedID("abcdefghijk"), "abcdefghi…hijk")
        XCTAssertEqual(AppAccount.maskedID("wxid_1234567890"), "wxid_1234…7890")
        // 脱敏后不得包含完整账号 ID（UI 只展示脱敏结果）。
        XCTAssertFalse(AppAccount.maskedID("wxid_1234567890").contains("wxid_1234567890"))
    }
}
