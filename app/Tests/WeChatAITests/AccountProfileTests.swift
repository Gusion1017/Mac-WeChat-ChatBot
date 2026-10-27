import Foundation
import XCTest
@testable import WeChatAI

/// `AccountLayout` / `AccountProfile`（账号档案、旧版迁移、claim）单测。
///
/// 所有路径注入到 temporaryDirectory；旧库用 `MemoryStore(databaseURL:)` 真实构造，
/// 夹具中的账号与人格均为占位符。
final class AccountProfileTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryRoot: URL!
    private var layout: AccountLayout!
    private var documentsRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("wechatai-account-profile-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        layout = AccountLayout(
            root: temporaryRoot.appendingPathComponent("support", isDirectory: true)
        )
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

    private func setModificationDate(_ url: URL, _ date: Date) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// 在假微信容器里创建 `<id>_abcd/temp`，让 resolver 能检测到该账号。
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

    /// 用真实 SQLite（MemoryStore）构造旧版单库，可选写入 `onebot.self_id`。
    private func createLegacyDatabase(selfID: String?) async throws {
        try fileManager.createDirectory(
            at: layout.legacyDatabaseFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = MemoryStore(databaseURL: layout.legacyDatabaseFile)
        try await store.open()
        if let selfID {
            try await store.setSetting(key: "onebot.self_id", value: selfID)
        }
        await store.close()
    }

    /// 读取某个库里的 `onebot.self_id`（用于验证复制出的库内容一致）。
    private func readSelfID(at databaseURL: URL) async throws -> String? {
        let store = MemoryStore(databaseURL: databaseURL)
        try await store.open()
        let value = try await store.setting(key: "onebot.self_id")
        await store.close()
        return value
    }

    /// 旧版 `config.json`：顶层含 bot/personas/schedules（升级时被种子化成 profile.json）。
    private func writeLegacyConfig() throws {
        try fileManager.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "schemaVersion": 1,
            "general": ["language": "zh-Hans"],
            "bot": ["enabled": true, "maxContextMessages": 12],
            "personas": [[
                "id": "persona-legacy-test",
                "name": "旧版人格",
                "summary": "",
                "systemPrompt": "legacy prompt",
                "isDefault": true,
            ]],
            "schedules": [[
                "id": "schedule-legacy-test",
                "name": "旧版任务",
                "enabled": false,
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try data.write(to: layout.legacyConfigFile, options: .atomic)
    }

    private func readState() throws -> AccountState {
        try JSONDecoder().decode(AccountState.self, from: Data(contentsOf: layout.stateFile))
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Layout

    func testLayoutPaths() {
        XCTAssertEqual(layout.accountsDirectory.path, layout.root.appendingPathComponent("accounts").path)
        XCTAssertEqual(layout.stateFile.path, layout.root.appendingPathComponent("account-state.json").path)
        XCTAssertEqual(layout.legacyDatabaseFile.path, layout.root.appendingPathComponent("chatbot.sqlite").path)
        XCTAssertEqual(layout.legacyMediaDirectory.path, layout.root.appendingPathComponent("media").path)
        XCTAssertEqual(layout.legacyConfigFile.path, layout.root.appendingPathComponent("config.json").path)

        let id = "wxid_layout_test"
        XCTAssertEqual(layout.directory(for: id).path, layout.accountsDirectory.appendingPathComponent(id).path)
        XCTAssertEqual(layout.databaseFile(for: id).path, layout.directory(for: id).appendingPathComponent("chatbot.sqlite").path)
        XCTAssertEqual(layout.profileFile(for: id).path, layout.directory(for: id).appendingPathComponent("profile.json").path)
        XCTAssertEqual(layout.mediaDirectory(for: id).path, layout.directory(for: id).appendingPathComponent("media").path)
        XCTAssertEqual(layout.logsDirectory(for: id).path, layout.directory(for: id).appendingPathComponent("logs").path)
        XCTAssertEqual(
            layout.legacyMigrationMarkerFile(for: id).path,
            layout.directory(for: id).appendingPathComponent("legacy-migration.json").path
        )
    }

    func testEnsureDirectoriesIsIdempotentAndRejectsInvalidIDs() {
        layout.ensureDirectories(for: "wxid_layout_test")
        layout.ensureDirectories(for: "wxid_layout_test")

        for url in [
            layout.accountsDirectory,
            layout.directory(for: "wxid_layout_test"),
            layout.mediaDirectory(for: "wxid_layout_test"),
            layout.logsDirectory(for: "wxid_layout_test"),
        ] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }

        // 非法 ID 不得创建任何目录（含 accounts/ 本身），也不能穿越到 root 之外。
        let cleanRoot = temporaryRoot.appendingPathComponent("clean", isDirectory: true)
        let cleanLayout = AccountLayout(root: cleanRoot)
        cleanLayout.ensureDirectories(for: "../evil")
        XCTAssertFalse(fileManager.fileExists(atPath: cleanLayout.accountsDirectory.path))
        XCTAssertFalse(fileManager.fileExists(atPath: temporaryRoot.appendingPathComponent("evil").path))

        // 保留名 _unassigned 是合法的临时档案目录。
        cleanLayout.ensureDirectories(for: AppAccount.unassignedID)
        XCTAssertTrue(fileManager.fileExists(atPath: cleanLayout.directory(for: AppAccount.unassignedID).path))
    }

    func testStateJSONShapeAndRoundtrip() throws {
        let state = AccountState(lastAccountID: "wxid_state_test", updatedAt: 1_761_000_000)
        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["lastAccountID"] as? String, "wxid_state_test")
        XCTAssertEqual(object["updatedAt"] as? Double, 1_761_000_000)

        let decoded = try JSONDecoder().decode(AccountState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    // MARK: - Active state

    func testDefaultActiveIsUnassigned() {
        XCTAssertEqual(AccountProfile.activeID, AppAccount.unassignedID)
        XCTAssertTrue(AccountProfile.isUnassigned)
        XCTAssertEqual(AccountProfile.maskedActiveID, "未识别")
        XCTAssertEqual(
            AccountProfile.databaseFile.path,
            layout.databaseFile(for: AppAccount.unassignedID).path
        )
    }

    func testActivateWritesStateAndCreatesAccountDirectories() throws {
        try AccountProfile.activate("wxid_activate_test")

        XCTAssertEqual(AccountProfile.activeID, "wxid_activate_test")
        XCTAssertFalse(AccountProfile.isUnassigned)
        XCTAssertEqual(AccountProfile.maskedActiveID, AppAccount.maskedID("wxid_activate_test"))
        XCTAssertEqual(
            AccountProfile.databaseFile.path,
            layout.databaseFile(for: "wxid_activate_test").path
        )

        var isDirectory: ObjCBool = false
        for url in [
            layout.directory(for: "wxid_activate_test"),
            layout.mediaDirectory(for: "wxid_activate_test"),
            layout.logsDirectory(for: "wxid_activate_test"),
        ] {
            XCTAssertTrue(fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }

        let state = try readState()
        XCTAssertEqual(state.schemaVersion, 1)
        XCTAssertEqual(state.lastAccountID, "wxid_activate_test")
        XCTAssertGreaterThan(state.updatedAt, 0)
    }

    func testActivateAllowsReservedUnassignedID() throws {
        try AccountProfile.activate("wxid_activate_test")
        // Lead runtime 切号失败时会显式回退到临时档案；保留名必须允许写入。
        try AccountProfile.activate(AppAccount.unassignedID)

        XCTAssertTrue(AccountProfile.isUnassigned)
        XCTAssertEqual(AccountProfile.activeID, AppAccount.unassignedID)
        XCTAssertEqual(try readState().lastAccountID, AppAccount.unassignedID)
    }

    func testActivateRejectsInvalidAccountIDs() {
        for invalid in ["../evil", "", "_other_reserved", "with space", "路径/账号"] {
            XCTAssertThrowsError(try AccountProfile.activate(invalid), "应拒绝非法账号 ID：\(invalid)")
        }
        XCTAssertEqual(AccountProfile.activeID, AppAccount.unassignedID)
        XCTAssertFalse(fileManager.fileExists(atPath: layout.stateFile.path))
    }

    // MARK: - preparePaths

    func testPreparePathsWithoutStateDoesNotWriteStateFile() throws {
        try makeDetectedAccount(id: "wxid_detected_test")

        AccountProfile.preparePaths()

        XCTAssertEqual(AccountProfile.activeID, "wxid_detected_test")
        XCTAssertNil(AccountProfile.pendingNotice)
        // 首次启动不能写 state，否则 runLegacyMigrationIfNeeded 会误以为迁移已完成。
        XCTAssertFalse(fileManager.fileExists(atPath: layout.stateFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: layout.directory(for: "wxid_detected_test").path))
    }

    func testPreparePathsDetectsSwitchAndWritesStateBack() throws {
        try AccountProfile.activate("wxid_alpha_test")
        try makeDetectedAccount(id: "wxid_beta_test")

        AccountProfile.preparePaths()

        XCTAssertEqual(AccountProfile.activeID, "wxid_beta_test")
        XCTAssertEqual(try readState().lastAccountID, "wxid_beta_test")

        let expectedNotice = "检测到微信账号已切换：\(AppAccount.maskedID("wxid_beta_test"))"
        XCTAssertEqual(AccountProfile.pendingNotice, expectedNotice)
        XCTAssertFalse(AccountProfile.pendingNotice?.contains("wxid_beta_test") == true, "notice 必须脱敏")

        // 重复调用：state 已写回 detected，不再重复提示，active 稳定。
        AccountProfile.preparePaths()
        XCTAssertEqual(AccountProfile.activeID, "wxid_beta_test")
        XCTAssertNil(AccountProfile.pendingNotice)
    }

    func testPreparePathsFallsBackToStoredStateWhenNotDetected() throws {
        try AccountProfile.activate("wxid_alpha_test")

        AccountProfile.preparePaths()

        XCTAssertEqual(AccountProfile.activeID, "wxid_alpha_test")
        XCTAssertNil(AccountProfile.pendingNotice)
        XCTAssertEqual(try readState().lastAccountID, "wxid_alpha_test")
    }

    func testPreparePathsIgnoresInvalidStoredAccountID() throws {
        try fileManager.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let invalidState = AccountState(lastAccountID: "../evil", updatedAt: 1_761_000_000)
        try JSONEncoder().encode(invalidState).write(to: layout.stateFile, options: .atomic)

        AccountProfile.preparePaths()

        XCTAssertEqual(AccountProfile.activeID, AppAccount.unassignedID)
    }

    // MARK: - claimUnassigned

    private func makeUnassignedProfileWithFiles() throws {
        let source = layout.directory(for: AppAccount.unassignedID)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("legacy-db".utf8).write(to: source.appendingPathComponent("chatbot.sqlite"))
        try Data("{}".utf8).write(to: source.appendingPathComponent("profile.json"))
        let media = source.appendingPathComponent("media", isDirectory: true)
        try fileManager.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: media.appendingPathComponent("pic.bin"))
    }

    func testClaimUnassignedCopiesDatabaseProfileAndMediaWithoutDeletingSource() throws {
        try makeUnassignedProfileWithFiles()

        let copied = try AccountProfile.claimUnassigned(by: "wxid_claim_test")

        XCTAssertTrue(copied)
        XCTAssertEqual(AccountProfile.activeID, AppAccount.unassignedID, "claim 本身不切换 active")
        XCTAssertFalse(fileManager.fileExists(atPath: layout.stateFile.path), "claim 不写 state")

        let destination = layout.directory(for: "wxid_claim_test")
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("chatbot.sqlite")),
            Data("legacy-db".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("profile.json")),
            Data("{}".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("media/pic.bin")),
            Data("image".utf8)
        )

        // 源目录与文件全部保留（契约：认领只 copy，不删除）。
        let source = layout.directory(for: AppAccount.unassignedID)
        XCTAssertTrue(fileManager.fileExists(atPath: source.appendingPathComponent("chatbot.sqlite").path))
        XCTAssertTrue(fileManager.fileExists(atPath: source.appendingPathComponent("profile.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: source.appendingPathComponent("media/pic.bin").path))

        // 目标已有库 → 不重复复制。
        XCTAssertFalse(try AccountProfile.claimUnassigned(by: "wxid_claim_test"))
    }

    func testClaimUnassignedReturnsFalseWhenTargetDatabaseExists() throws {
        try makeUnassignedProfileWithFiles()
        layout.ensureDirectories(for: "wxid_claim_test")
        let existing = layout.databaseFile(for: "wxid_claim_test")
        try Data("existing-db".utf8).write(to: existing)

        XCTAssertFalse(try AccountProfile.claimUnassigned(by: "wxid_claim_test"))
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing-db".utf8))
    }

    func testClaimUnassignedReturnsFalseWhenActiveIsAssigned() throws {
        try AccountProfile.activate("wxid_alpha_test")
        try makeUnassignedProfileWithFiles()

        XCTAssertFalse(try AccountProfile.claimUnassigned(by: "wxid_claim_test"))
        XCTAssertFalse(fileManager.fileExists(atPath: layout.directory(for: "wxid_claim_test").appendingPathComponent("chatbot.sqlite").path))
    }

    func testClaimUnassignedRejectsInvalidID() {
        XCTAssertThrowsError(try AccountProfile.claimUnassigned(by: "../evil"))
        XCTAssertThrowsError(try AccountProfile.claimUnassigned(by: AppAccount.unassignedID))
    }

    // MARK: - Legacy migration: no database

    func testMigrationWithoutLegacyDatabaseWritesStateOnly() {
        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertFalse(outcome.didMigrate)
        XCTAssertNil(outcome.legacyOwnerAccountID)
        XCTAssertNil(outcome.notice)
        XCTAssertEqual(outcome.activeAccountID, AppAccount.unassignedID)
        XCTAssertEqual(try? readState().lastAccountID, AppAccount.unassignedID)
    }

    func testMigrationSeedsProfileFromLegacyConfigWithoutDatabase() throws {
        // 用 resolver 检测出账号（不写 state），模拟“只剩 config.json”的升级首启。
        try makeDetectedAccount(id: "wxid_active_test")
        AccountProfile.preparePaths()
        XCTAssertEqual(AccountProfile.activeID, "wxid_active_test")
        XCTAssertFalse(fileManager.fileExists(atPath: layout.stateFile.path))
        try writeLegacyConfig()

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertTrue(outcome.didMigrate, "只剩 config.json 时也应恢复账号级设置")
        XCTAssertEqual(outcome.activeAccountID, "wxid_active_test")
        XCTAssertNil(outcome.legacyOwnerAccountID)
        XCTAssertNotNil(outcome.notice)

        let profile = try readJSON(layout.profileFile(for: "wxid_active_test"))
        XCTAssertEqual(profile["schemaVersion"] as? Int, 1)
        let bot = try XCTUnwrap(profile["bot"] as? [String: Any])
        XCTAssertEqual(bot["maxContextMessages"] as? Int, 12)
        let personas = try XCTUnwrap(profile["personas"] as? [Any])
        XCTAssertEqual(personas.count, 1)
        XCTAssertEqual((personas.first as? [String: Any])?["id"] as? String, "persona-legacy-test")
        XCTAssertEqual((profile["schedules"] as? [Any])?.count, 1)

        XCTAssertEqual(try readState().lastAccountID, "wxid_active_test")
        // 没有旧库 → 不复制数据库；旧 config 保留。
        XCTAssertFalse(fileManager.fileExists(atPath: layout.databaseFile(for: "wxid_active_test").path))
        XCTAssertTrue(fileManager.fileExists(atPath: layout.legacyConfigFile.path))
    }

    func testMigrationConfigOnlyDoesNotSeedProfileForUnassignedActive() {
        XCTAssertNoThrow(try writeLegacyConfig())

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertFalse(outcome.didMigrate)
        XCTAssertNil(outcome.notice)
        XCTAssertEqual(outcome.activeAccountID, AppAccount.unassignedID)
        XCTAssertFalse(fileManager.fileExists(atPath: layout.profileFile(for: AppAccount.unassignedID).path))
        XCTAssertEqual(try? readState().lastAccountID, AppAccount.unassignedID)
    }

    // MARK: - Legacy migration: database present

    func testMigrationOwnerEqualsActiveCopiesDatabaseAndSeedsProfile() async throws {
        let activeID = "wxid_owner_test"
        try makeDetectedAccount(id: activeID)
        AccountProfile.preparePaths()
        XCTAssertEqual(AccountProfile.activeID, activeID)
        XCTAssertFalse(fileManager.fileExists(atPath: layout.stateFile.path))

        try await createLegacyDatabase(selfID: activeID)
        try writeLegacyConfig()
        try fileManager.createDirectory(at: layout.legacyMediaDirectory, withIntermediateDirectories: true)

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertTrue(outcome.didMigrate)
        XCTAssertEqual(outcome.activeAccountID, activeID)
        XCTAssertEqual(outcome.legacyOwnerAccountID, activeID)
        XCTAssertNotNil(outcome.notice)

        let targetDatabase = layout.databaseFile(for: activeID)
        XCTAssertTrue(fileManager.fileExists(atPath: targetDatabase.path))
        let copiedSelfID = try await readSelfID(at: targetDatabase)
        XCTAssertEqual(copiedSelfID, activeID)

        let profile = try readJSON(layout.profileFile(for: activeID))
        XCTAssertNotNil(profile["bot"] as? [String: Any])
        XCTAssertEqual((profile["personas"] as? [Any])?.count, 1)
        XCTAssertNotNil(profile["schedules"] as? [Any])

        let marker = try readJSON(layout.legacyMigrationMarkerFile(for: activeID))
        XCTAssertEqual(marker["schemaVersion"] as? Int, 1)
        XCTAssertEqual(marker["targetAccountID"] as? String, activeID)
        XCTAssertEqual(marker["legacyOwnerAccountID"] as? String, activeID)
        XCTAssertEqual(marker["copiedDatabase"] as? Bool, true)
        XCTAssertEqual(marker["seededProfile"] as? Bool, true)

        XCTAssertEqual(try readState().lastAccountID, activeID)

        // 旧文件一律保留。
        XCTAssertTrue(fileManager.fileExists(atPath: layout.legacyDatabaseFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: layout.legacyConfigFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: layout.legacyMediaDirectory.path))
    }

    func testMigrationOwnerDiffersFromActiveCopiesToOwnerButKeepsActive() async throws {
        let activeID = "wxid_active_test"
        let ownerID = "wxid_owner_other_test"
        try makeDetectedAccount(id: activeID)
        AccountProfile.preparePaths()
        XCTAssertEqual(AccountProfile.activeID, activeID)

        try await createLegacyDatabase(selfID: ownerID)

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertTrue(outcome.didMigrate)
        XCTAssertEqual(outcome.legacyOwnerAccountID, ownerID)
        // 当前 active 不是 unassigned → 保持当前账号，不把用户切到旧 owner。
        XCTAssertEqual(outcome.activeAccountID, activeID)
        XCTAssertEqual(AccountProfile.activeID, activeID)
        XCTAssertEqual(try readState().lastAccountID, activeID)

        XCTAssertTrue(fileManager.fileExists(atPath: layout.databaseFile(for: ownerID).path))
        XCTAssertFalse(fileManager.fileExists(atPath: layout.databaseFile(for: activeID).path))

        let maskedOwner = AppAccount.maskedID(ownerID)
        let notice = try XCTUnwrap(outcome.notice)
        XCTAssertTrue(notice.contains(maskedOwner))
        XCTAssertFalse(notice.contains(ownerID), "notice 必须脱敏")
    }

    func testMigrationInvalidOwnerFallsBackToActive() async throws {
        let activeID = "wxid_active_test"
        try makeDetectedAccount(id: activeID)
        AccountProfile.preparePaths()

        try await createLegacyDatabase(selfID: "../invalid owner")

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertTrue(outcome.didMigrate)
        XCTAssertNil(outcome.legacyOwnerAccountID)
        XCTAssertEqual(outcome.activeAccountID, activeID)
        XCTAssertTrue(fileManager.fileExists(atPath: layout.databaseFile(for: activeID).path))
        // 数据库原样复制（owner 非法不影响数据内容），目标是当前 active。
        let copiedSelfID = try await readSelfID(at: layout.databaseFile(for: activeID))
        XCTAssertEqual(copiedSelfID, "../invalid owner")
        let notice = try XCTUnwrap(outcome.notice)
        XCTAssertTrue(notice.contains(AppAccount.maskedID(activeID)))
    }

    func testMigrationNoOwnerStaysUnassigned() async throws {
        try await createLegacyDatabase(selfID: nil)

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertTrue(outcome.didMigrate)
        XCTAssertNil(outcome.legacyOwnerAccountID)
        XCTAssertEqual(outcome.activeAccountID, AppAccount.unassignedID)
        XCTAssertTrue(fileManager.fileExists(atPath: layout.databaseFile(for: AppAccount.unassignedID).path))
        XCTAssertEqual(try readState().lastAccountID, AppAccount.unassignedID)
        XCTAssertTrue(outcome.notice?.contains("未识别") == true)
    }

    func testMigrationIsIdempotent() async throws {
        let activeID = "wxid_owner_test"
        try makeDetectedAccount(id: activeID)
        AccountProfile.preparePaths()
        try await createLegacyDatabase(selfID: activeID)
        try writeLegacyConfig()

        let first = AccountProfile.runLegacyMigrationIfNeeded()
        XCTAssertTrue(first.didMigrate)
        let stateData = try Data(contentsOf: layout.stateFile)
        let markerData = try Data(contentsOf: layout.legacyMigrationMarkerFile(for: activeID))

        let second = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertFalse(second.didMigrate)
        XCTAssertEqual(second.activeAccountID, first.activeAccountID)
        XCTAssertEqual(try Data(contentsOf: layout.stateFile), stateData, "重复调用不得改写 state")
        XCTAssertEqual(
            try Data(contentsOf: layout.legacyMigrationMarkerFile(for: activeID)),
            markerData,
            "重复调用不得改写 legacy-migration.json"
        )
    }

    func testMigrationSkipsWhenStateExists() async throws {
        try AccountProfile.activate("wxid_active_test")
        try await createLegacyDatabase(selfID: "wxid_owner_other_test")

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertFalse(outcome.didMigrate)
        XCTAssertEqual(outcome.activeAccountID, "wxid_active_test")
        XCTAssertNil(outcome.legacyOwnerAccountID)
        XCTAssertNil(outcome.notice)
        XCTAssertEqual(try readState().lastAccountID, "wxid_active_test")
        XCTAssertFalse(fileManager.fileExists(atPath: layout.directory(for: "wxid_owner_other_test").path))
    }

    func testMigrationDoesNotOverwriteExistingTargetDatabase() async throws {
        let ownerID = "wxid_owner_test"
        // 目标账号之前已经迁移过：库存在且带哨兵值。
        try fileManager.createDirectory(at: layout.directory(for: ownerID), withIntermediateDirectories: true)
        let targetDatabase = layout.databaseFile(for: ownerID)
        let targetStore = MemoryStore(databaseURL: targetDatabase)
        try await targetStore.open()
        try await targetStore.setSetting(key: "onebot.self_id", value: "sentinel")
        await targetStore.close()

        try await createLegacyDatabase(selfID: ownerID)

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()

        XCTAssertTrue(outcome.didMigrate)
        let preservedSelfID = try await readSelfID(at: targetDatabase)
        XCTAssertEqual(preservedSelfID, "sentinel", "目标库已存在时不得覆盖")

        let marker = try readJSON(layout.legacyMigrationMarkerFile(for: ownerID))
        XCTAssertEqual(marker["copiedDatabase"] as? Bool, false)
    }

    func testMigrationUsesConsistentSnapshotWhileLegacyDatabaseIsOpen() async throws {
        // 旧 App 实例还开着库（WAL 中可能有未 checkpoint 的数据）时，Backup API 仍应得到一致快照。
        let ownerID = "wxid_wal_owner_test"
        let legacyStore = MemoryStore(databaseURL: layout.legacyDatabaseFile)
        try await legacyStore.open()
        try await legacyStore.setSetting(key: "onebot.self_id", value: ownerID)

        let outcome = AccountProfile.runLegacyMigrationIfNeeded()
        await legacyStore.close()

        XCTAssertTrue(outcome.didMigrate)
        XCTAssertEqual(outcome.legacyOwnerAccountID, ownerID)
        XCTAssertEqual(outcome.activeAccountID, ownerID)
        let copiedSelfID = try await readSelfID(at: layout.databaseFile(for: ownerID))
        XCTAssertEqual(copiedSelfID, ownerID)
    }

    // MARK: - Saved accounts

    func testSavedAccountsExcludesUnassignedAndSortsByLastUse() throws {
        try AccountProfile.activate("wxid_beta_test")

        layout.ensureDirectories(for: "wxid_alpha_test")
        let alphaDatabase = layout.databaseFile(for: "wxid_alpha_test")
        try Data("db".utf8).write(to: alphaDatabase)
        try setModificationDate(alphaDatabase, Date(timeIntervalSince1970: 1_700_000_000))

        // 临时档案目录存在也不应出现在「已保存的账号」里。
        layout.ensureDirectories(for: AppAccount.unassignedID)

        let accounts = AccountProfile.savedAccounts()
        XCTAssertEqual(accounts.map(\.id), ["wxid_beta_test", "wxid_alpha_test"])
        XCTAssertEqual(accounts.first?.isActive, true)
        XCTAssertEqual(accounts.first?.maskedID, AppAccount.maskedID("wxid_beta_test"))
        XCTAssertEqual(accounts.last?.isActive, false)
        XCTAssertEqual(accounts.last?.maskedID, AppAccount.maskedID("wxid_alpha_test"))
        XCTAssertFalse(accounts.contains { $0.id == AppAccount.unassignedID })

        XCTAssertEqual(AccountProfile.savedAccounts(limit: 1).count, 1)
        XCTAssertEqual(AccountProfile.savedAccounts(limit: 10).count, 2)
        XCTAssertTrue(AccountProfile.savedAccounts(limit: 0).isEmpty)
    }

    // MARK: - Resolver-backed helpers

    func testDetectedAccountAndActiveImageDirectory() throws {
        let detectedDirectory = try makeDetectedAccount(id: "wxid_detected_test")

        AccountProfile.preparePaths()
        XCTAssertEqual(AccountProfile.detectedAccountID(), "wxid_detected_test")
        // 解析符号链接后再比较：FileManager 列举出的 URL 可能是 /private/var/...。
        XCTAssertEqual(
            AccountProfile.activeImageDirectory()?.resolvingSymlinksInPath().path,
            detectedDirectory.appendingPathComponent("temp", isDirectory: true).resolvingSymlinksInPath().path
        )

        // 切到一个在微信容器里没有数据目录的账号 → 图片目录为 nil。
        try AccountProfile.activate("wxid_no_wechat_dir_test")
        XCTAssertNil(AccountProfile.activeImageDirectory())
        XCTAssertEqual(AccountProfile.detectedAccountID(), "wxid_detected_test")
    }
}
