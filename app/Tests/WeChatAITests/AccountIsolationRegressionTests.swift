import Foundation
import XCTest
@testable import WeChatAI

/// 账号隔离回归测试（2026-10-28 审查修复）：
/// - `_unassigned` 有数据时，下次启动检测到账号必须认领，不能被 preparePaths 直接改 active；
/// - 旧库迁移的 `legacyMigrationDone` 门禁不能被 activate/切号误置；
/// - 迁移/认领遇到“提前开库留下的空库”时可替换，已有数据不覆盖；
/// - `MemoryStore.suspend()` 期间禁止隐式 open，切库恢复后正常写入。
final class AccountIsolationRegressionTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryRoot: URL!
    private var layout: AccountLayout!
    private var documentsRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("wechatai-account-regression-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        layout = AccountLayout(root: temporaryRoot.appendingPathComponent("support", isDirectory: true))
        documentsRoot = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        AccountProfile.configureForTesting(
            layout: layout,
            resolver: WeChatAccountResolver(documentsRoot: documentsRoot)
        )
    }

    override func tearDownWithError() throws {
        AccountProfile.resetForTesting()
        if let temporaryRoot {
            try? fileManager.removeItem(at: temporaryRoot)
        }
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeDetectedAccount(id: String, suffix: String = "abcd") throws -> URL {
        let directory = documentsRoot
            .appendingPathComponent("xwechat_files/\(id)_\(suffix)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory.appendingPathComponent("temp", isDirectory: true),
            withIntermediateDirectories: true
        )
        return directory
    }

    private func writeState(lastAccountID: String, legacyMigrationDone: Bool) throws {
        try fileManager.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let state = AccountState(
            lastAccountID: lastAccountID,
            updatedAt: 1_761_000_000,
            legacyMigrationDone: legacyMigrationDone
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: layout.stateFile, options: .atomic)
    }

    private func readState() throws -> AccountState {
        try JSONDecoder().decode(AccountState.self, from: Data(contentsOf: layout.stateFile))
    }

    private func createDatabase(at url: URL, selfID: String) async throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = MemoryStore(databaseURL: url)
        try await store.open()
        try await store.setSetting(key: "onebot.self_id", value: selfID)
        await store.close()
    }

    private func readSelfID(at url: URL) async throws -> String? {
        let store = MemoryStore(databaseURL: url)
        try await store.open()
        let value = try await store.setting(key: "onebot.self_id")
        await store.close()
        return value
    }

    private func writeProfile(for id: String, keyword: String) throws {
        var bot = BotSettings()
        bot.keywords = [keyword]
        let profile = ProfileSettings(bot: bot)
        let directory = layout.directory(for: id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(profile).write(to: layout.profileFile(for: id), options: .atomic)
    }

    // MARK: - _unassigned 认领

    func testPreparePathsKeepsUnassignedWhenItHasDataAndAccountIsDetected() async throws {
        try writeState(lastAccountID: AppAccount.unassignedID, legacyMigrationDone: true)
        try await createDatabase(at: layout.databaseFile(for: AppAccount.unassignedID), selfID: "wxid_unassigned_old")
        try makeDetectedAccount(id: "wxid_detected_new")

        AccountProfile.preparePaths()

        XCTAssertEqual(AccountProfile.activeID, AppAccount.unassignedID)
        XCTAssertEqual(try readState().lastAccountID, AppAccount.unassignedID, "state 不能被提前改成 detected，否则迁移门禁会跳过认领")
        XCTAssertEqual(AccountProfile.pendingNotice?.contains("已识别微信账号") ?? false, true)
    }

    func testPreparePathsSwitchesToDetectedWhenUnassignedHasNoData() throws {
        try writeState(lastAccountID: AppAccount.unassignedID, legacyMigrationDone: true)
        try makeDetectedAccount(id: "wxid_detected_new")

        AccountProfile.preparePaths()

        XCTAssertEqual(AccountProfile.activeID, "wxid_detected_new")
        XCTAssertEqual(try readState().lastAccountID, "wxid_detected_new")
    }

    func testStartupClaimMovesUnassignedDataIntoDetectedAccount() async throws {
        try writeState(lastAccountID: AppAccount.unassignedID, legacyMigrationDone: true)
        try await createDatabase(at: layout.databaseFile(for: AppAccount.unassignedID), selfID: "wxid_unassigned_old")
        try writeProfile(for: AppAccount.unassignedID, keyword: "未识别关键词")
        let unassignedMedia = layout.mediaDirectory(for: AppAccount.unassignedID)
            .appendingPathComponent("2026-10-27/pic.jpg")
        try fileManager.createDirectory(
            at: unassignedMedia.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("image".utf8).write(to: unassignedMedia)
        try makeDetectedAccount(id: "wxid_detected_new")

        AccountProfile.preparePaths()
        XCTAssertEqual(AccountProfile.activeID, AppAccount.unassignedID)

        let outcome = AccountProfile.claimUnassignedForStartup(detectedAccountID: "wxid_detected_new")

        XCTAssertTrue(outcome.didClaim)
        XCTAssertEqual(outcome.activeAccountID, "wxid_detected_new")
        XCTAssertEqual(AccountProfile.activeID, "wxid_detected_new")
        XCTAssertEqual(try readState().lastAccountID, "wxid_detected_new")
        let claimedSelfID = try await readSelfID(at: layout.databaseFile(for: "wxid_detected_new"))
        XCTAssertEqual(claimedSelfID, "wxid_unassigned_old")
        XCTAssertEqual(
            try Data(contentsOf: layout.profileFile(for: "wxid_detected_new")),
            try Data(contentsOf: layout.profileFile(for: AppAccount.unassignedID))
        )
        XCTAssertTrue(fileManager.fileExists(
            atPath: layout.mediaDirectory(for: "wxid_detected_new")
                .appendingPathComponent("2026-10-27/pic.jpg").path
        ))
        XCTAssertTrue(
            fileManager.fileExists(atPath: layout.databaseFile(for: AppAccount.unassignedID).path),
            "源 _unassigned 必须保留"
        )
    }

    func testStartupClaimDoesNotOverwriteExistingTargetData() async throws {
        try writeState(lastAccountID: AppAccount.unassignedID, legacyMigrationDone: true)
        try await createDatabase(at: layout.databaseFile(for: AppAccount.unassignedID), selfID: "wxid_unassigned_old")
        try await createDatabase(at: layout.databaseFile(for: "wxid_detected_new"), selfID: "sentinel")

        let outcome = AccountProfile.claimUnassignedForStartup(detectedAccountID: "wxid_detected_new")

        XCTAssertFalse(outcome.didClaim)
        let preservedSelfID = try await readSelfID(at: layout.databaseFile(for: "wxid_detected_new"))
        XCTAssertEqual(preservedSelfID, "sentinel")
    }

    func testStartupClaimReplacesPrecreatedEmptyTargetDatabase() async throws {
        try writeState(lastAccountID: AppAccount.unassignedID, legacyMigrationDone: true)
        try await createDatabase(at: layout.databaseFile(for: AppAccount.unassignedID), selfID: "wxid_unassigned_old")
        // 模拟切号/提前开库留下的空库（只有 schema）。
        let emptyStore = MemoryStore(databaseURL: layout.databaseFile(for: "wxid_detected_new"))
        try await emptyStore.open()
        await emptyStore.close()

        let outcome = AccountProfile.claimUnassignedForStartup(detectedAccountID: "wxid_detected_new")

        XCTAssertTrue(outcome.didClaim)
        let claimedSelfID = try await readSelfID(at: layout.databaseFile(for: "wxid_detected_new"))
        XCTAssertEqual(claimedSelfID, "wxid_unassigned_old")
    }

    // MARK: - 迁移门禁

    func testMigrationRetriesWhenStateExistsButMigrationNotDone() async throws {
        try writeState(lastAccountID: "wxid_owner_test", legacyMigrationDone: false)
        let legacy = MemoryStore(databaseURL: layout.legacyDatabaseFile)
        try await legacy.open()
        try await legacy.setSetting(key: "onebot.self_id", value: "wxid_owner_test")
        await legacy.close()

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertTrue(outcome.didMigrate)
        XCTAssertEqual(outcome.activeAccountID, "wxid_owner_test")
        XCTAssertEqual(try readState().legacyMigrationDone, true)
        let migratedSelfID = try await readSelfID(at: layout.databaseFile(for: "wxid_owner_test"))
        XCTAssertEqual(migratedSelfID, "wxid_owner_test")
    }

    func testActivatePreservesMigrationDoneFlag() throws {
        try writeState(lastAccountID: "wxid_a", legacyMigrationDone: false)
        try AccountProfile.activate("wxid_b")
        XCTAssertEqual(try readState().lastAccountID, "wxid_b")
        XCTAssertEqual(try readState().legacyMigrationDone, false, "切号不能替代旧库迁移完成标记")
    }

    func testMigrationHandlesWalDatabaseWithoutSidecars() async throws {
        let ownerID = "wxid_wal_owner_test"
        let legacy = MemoryStore(databaseURL: layout.legacyDatabaseFile)
        try await legacy.open()
        try await legacy.setSetting(key: "onebot.self_id", value: ownerID)
        try await legacy.upsertConversation(Conversation(id: "wxid_friend_test", kind: .direct, title: "旧会话"))
        await legacy.close()
        // 旧 App 干净退出后常见：主库仍是 WAL 模式，但 -wal/-shm 已被删除。
        try? fileManager.removeItem(atPath: layout.legacyDatabaseFile.path + "-wal")
        try? fileManager.removeItem(atPath: layout.legacyDatabaseFile.path + "-shm")

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertTrue(outcome.didMigrate, outcome.notice ?? "no notice")
        let migratedSelfID = try await readSelfID(at: layout.databaseFile(for: ownerID))
        XCTAssertEqual(migratedSelfID, ownerID)
        let store = MemoryStore(databaseURL: layout.databaseFile(for: ownerID))
        try await store.open()
        let conversations = try await store.fetchConversations()
        await store.close()
        XCTAssertEqual(conversations.map(\.id), ["wxid_friend_test"])
    }

    func testMigrationReplacesPrecreatedEmptyTargetDatabase() async throws {
        try writeState(lastAccountID: "wxid_owner_test", legacyMigrationDone: false)
        let legacy = MemoryStore(databaseURL: layout.legacyDatabaseFile)
        try await legacy.open()
        try await legacy.setSetting(key: "onebot.self_id", value: "wxid_owner_test")
        await legacy.close()
        // 模拟迁移前提前打开过目标账号库：只有 schema 的空库。
        let emptyTarget = MemoryStore(databaseURL: layout.databaseFile(for: "wxid_owner_test"))
        try await emptyTarget.open()
        await emptyTarget.close()

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertTrue(outcome.didMigrate)
        let migratedSelfID = try await readSelfID(at: layout.databaseFile(for: "wxid_owner_test"))
        XCTAssertEqual(migratedSelfID, "wxid_owner_test")
    }

    // MARK: - MemoryStore suspend

    func testSuspendBlocksImplicitOpenAndSwitchResumes() async throws {
        let first = temporaryRoot.appendingPathComponent("a/chatbot.sqlite")
        let second = temporaryRoot.appendingPathComponent("b/chatbot.sqlite")
        let store = MemoryStore(databaseURL: first)
        try await store.open()
        try await store.setSetting(key: "k", value: "A")
        await store.suspend()

        do {
            try await store.setSetting(key: "k", value: "should-fail")
            XCTFail("suspend 后隐式 ensureOpen 不应重新打开旧库")
        } catch {
            // expected
        }

        try await store.switchDatabase(to: second)
        try await store.setSetting(key: "k", value: "B")
        let value = try await store.setting(key: "k")
        XCTAssertEqual(value, "B")
        await store.close()
    }
}
