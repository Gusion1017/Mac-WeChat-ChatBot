import Foundation
import XCTest
@testable import WeChatAI

/// 4.1.15.55 R3 产品接入的配置层测试：
/// - 旧 config.json（无 enableNativeSend）必须能解码且默认开启 R3；
/// - 运行期配置合并只覆盖 App 指定的键，仓库 JSON 保持默认 off。
final class NativeSendConfigTests: XCTestCase {
    func testHookSettingsDecodesLegacyConfigWithNativeSendDefaultEnabled() throws {
        let legacy = """
        {
          "wechatPath": "/Applications/WeChat.app",
          "gadgetPort": 27042,
          "autoLaunchWeChat": true,
          "autoStartBridge": true,
          "versionConfigPath": "",
          "lastBackupPath": "",
          "didInstallGadget": true
        }
        """
        let settings = try JSONDecoder().decode(HookSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.wechatPath, "/Applications/WeChat.app")
        XCTAssertEqual(settings.gadgetPort, 27042)
        XCTAssertTrue(settings.didInstallGadget)
        XCTAssertTrue(settings.enableNativeSend, "旧配置缺键时应默认开启 4.1.15.55 R3 发送")
    }

    func testHookSettingsRoundTripsEnableNativeSend() throws {
        var settings = HookSettings()
        settings.enableNativeSend = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HookSettings.self, from: data)
        XCTAssertFalse(decoded.enableNativeSend)
    }

    func testMaterializedVersionConfigAppliesOverridesOnly() throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("wechatai-native-send-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: baseDirectory) }

        let base = baseDirectory.appendingPathComponent("4_1_15_55_mac.json")
        let baseObject: [String: Any] = [
            "enableSend": "false",
            "req2bufSendMode": "off",
            "structVer": "2",
            "sendFuncAddr": "0x597eda0"
        ]
        let baseData = try JSONSerialization.data(withJSONObject: baseObject, options: [.prettyPrinted])
        try baseData.write(to: base)

        let outputDirectory = baseDirectory.appendingPathComponent("runtime", isDirectory: true)
        let overrides = [
            "enableSend": "true",
            "req2bufSendMode": "r3",
            "r3QueueUntilSeed": "true"
        ]
        let url = try XCTUnwrap(AppResources.materializedVersionConfig(
            version: "4.1.15.55",
            build: "270135",
            explicitPath: base.path,
            overrides: overrides,
            outputDirectory: outputDirectory
        ))
        XCTAssertEqual(url.lastPathComponent, "hook-4.1.15.55-270135.json")

        let merged = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(merged["enableSend"] as? String, "true")
        XCTAssertEqual(merged["req2bufSendMode"] as? String, "r3")
        XCTAssertEqual(merged["r3QueueUntilSeed"] as? String, "true")
        XCTAssertEqual(merged["structVer"] as? String, "2", "未覆盖的键必须保持仓库原值")
        XCTAssertEqual(merged["sendFuncAddr"] as? String, "0x597eda0")
    }
}
