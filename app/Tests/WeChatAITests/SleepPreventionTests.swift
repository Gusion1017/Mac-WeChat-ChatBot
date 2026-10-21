import XCTest
@testable import WeChatAI

/// Unit tests for the idle-sleep prevention preference and its pure decision logic.
///
/// These tests never call IOKit assertion APIs: they only decode/encode settings and
/// exercise `SleepPreventionCenter.shouldPreventSleep`, so running them cannot change
/// the machine's sleep state.
final class SleepPreventionTests: XCTestCase {
    // MARK: - Backwards-compatible settings decoding

    func testLegacyGeneralSettingsWithoutSleepPreventionFallsBackToNever() throws {
        let json = """
        {
          "appearance": "dark",
          "showInMenuBar": false,
          "launchAtLogin": true,
          "notificationsEnabled": false,
          "soundEnabled": true,
          "confirmBeforeQuit": false,
          "showDockIcon": false,
          "language": "en"
        }
        """

        let settings = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.sleepPrevention, .never)
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertFalse(settings.showInMenuBar)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertTrue(settings.soundEnabled)
        XCTAssertFalse(settings.confirmBeforeQuit)
        XCTAssertFalse(settings.showDockIcon)
        XCTAssertEqual(settings.language, "en")
    }

    func testLegacyConfigFileWithoutSleepPreventionStillLoads() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var general = try XCTUnwrap(root["general"] as? [String: Any])
        XCTAssertNotNil(general["sleepPrevention"], "新配置应写入 sleepPrevention")
        general.removeValue(forKey: "sleepPrevention")
        root["general"] = general
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertEqual(decoded.general.sleepPrevention, .never)
        XCTAssertEqual(decoded.general, AppSettings.default.general)
    }

    func testUnknownSleepPreventionRawValueFallsBackToNever() throws {
        let json = """
        {
          "appearance": "unknown-appearance",
          "sleepPrevention": "sometimes"
        }
        """

        let settings = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.sleepPrevention, .never)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.language, "system")
    }

    func testSleepPreventionEncodingRoundtrip() throws {
        var settings = GeneralSettings()
        settings.appearance = .light
        settings.showInMenuBar = false
        settings.sleepPrevention = .externalPowerOnly

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["sleepPrevention"] as? String, SleepPreventionMode.externalPowerOnly.rawValue)

        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - Mode metadata

    func testSleepPreventionModeRawValuesAndLabels() {
        XCTAssertEqual(SleepPreventionMode.allCases.map(\.rawValue), ["never", "externalPowerOnly", "always"])
        XCTAssertEqual(SleepPreventionMode.never.label, "永不")
        XCTAssertEqual(SleepPreventionMode.externalPowerOnly.label, "接入电源时")
        XCTAssertEqual(SleepPreventionMode.always.label, "始终")
        XCTAssertEqual(Set(SleepPreventionMode.allCases.map(\.id)).count, 3)
    }

    func testSleepPreventionModeDetailsAreNonEmpty() {
        for mode in SleepPreventionMode.allCases {
            XCTAssertFalse(mode.label.isEmpty, "\(mode.rawValue) 缺少标签")
            XCTAssertFalse(mode.detail.isEmpty, "\(mode.rawValue) 缺少说明")
        }
        XCTAssertEqual(SleepPreventionMode.never.rawValue, "never")
        XCTAssertTrue(SleepPreventionMode.externalPowerOnly.detail.contains("电池"))
        XCTAssertTrue(SleepPreventionMode.always.detail.contains("电池"))
    }

    // MARK: - Decision table

    func testShouldPreventSleepNever() {
        XCTAssertFalse(SleepPreventionCenter.shouldPreventSleep(mode: .never, onExternalPower: true))
        XCTAssertFalse(SleepPreventionCenter.shouldPreventSleep(mode: .never, onExternalPower: false))
    }

    func testShouldPreventSleepAlways() {
        XCTAssertTrue(SleepPreventionCenter.shouldPreventSleep(mode: .always, onExternalPower: true))
        XCTAssertTrue(SleepPreventionCenter.shouldPreventSleep(mode: .always, onExternalPower: false))
    }

    func testShouldPreventSleepExternalPowerOnly() {
        XCTAssertTrue(SleepPreventionCenter.shouldPreventSleep(mode: .externalPowerOnly, onExternalPower: true))
        XCTAssertFalse(SleepPreventionCenter.shouldPreventSleep(mode: .externalPowerOnly, onExternalPower: false))
    }
}
