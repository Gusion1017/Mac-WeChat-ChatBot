import XCTest
@testable import WeChatAI

/// 2026-10-26：总览「设备与账户」的数据层（电池解析 / DeepSeek 余额查询）。
///
/// 电池测试只喂合成字典，不读取测试机真实电源状态；余额测试只测地址推导与
/// JSON 解析，不发起网络请求，因此不需要真实 API Key。
final class SystemVitalsTests: XCTestCase {
    // MARK: - Battery

    func testBatteryParsingWhileCharging() throws {
        let description: [String: Any] = [
            BatteryReader.isPresentKey: NSNumber(value: true),
            BatteryReader.currentCapacityKey: NSNumber(value: 42),
            BatteryReader.maxCapacityKey: NSNumber(value: 80),
            BatteryReader.isChargingKey: NSNumber(value: true),
            BatteryReader.isChargedKey: NSNumber(value: false),
            BatteryReader.powerSourceStateKey: BatteryReader.acPowerValue,
            BatteryReader.timeToFullChargeKey: NSNumber(value: 95),
            BatteryReader.typeKey: BatteryReader.internalBatteryType
        ]

        let status = try XCTUnwrap(BatteryReader.parse(description: description))

        XCTAssertTrue(status.isPresent)
        XCTAssertEqual(status.percentage, 53, "42/80 四舍五入为 53%")
        XCTAssertTrue(status.isCharging)
        XCTAssertFalse(status.isFullyCharged)
        XCTAssertTrue(status.isOnExternalPower)
        XCTAssertEqual(status.timeRemainingMinutes, 95)
    }

    func testBatteryParsingOnBatteryPower() throws {
        let description: [String: Any] = [
            BatteryReader.isPresentKey: NSNumber(value: true),
            BatteryReader.currentCapacityKey: NSNumber(value: 10),
            BatteryReader.maxCapacityKey: NSNumber(value: 100),
            BatteryReader.isChargingKey: NSNumber(value: false),
            BatteryReader.isChargedKey: NSNumber(value: false),
            BatteryReader.powerSourceStateKey: BatteryReader.batteryPowerValue,
            BatteryReader.timeToEmptyKey: NSNumber(value: 215)
        ]

        let status = try XCTUnwrap(BatteryReader.parse(description: description))

        XCTAssertEqual(status.percentage, 10)
        XCTAssertFalse(status.isOnExternalPower)
        XCTAssertFalse(status.isCharging)
        XCTAssertEqual(status.timeRemainingMinutes, 215)
    }

    func testBatteryFullyChargedHidesZeroMinuteEstimate() throws {
        let description: [String: Any] = [
            BatteryReader.isPresentKey: NSNumber(value: true),
            BatteryReader.currentCapacityKey: NSNumber(value: 100),
            BatteryReader.maxCapacityKey: NSNumber(value: 100),
            BatteryReader.isChargingKey: NSNumber(value: false),
            BatteryReader.isChargedKey: NSNumber(value: true),
            BatteryReader.powerSourceStateKey: BatteryReader.acPowerValue,
            BatteryReader.timeToFullChargeKey: NSNumber(value: 0),
            BatteryReader.timeToEmptyKey: NSNumber(value: 0)
        ]

        let status = try XCTUnwrap(BatteryReader.parse(description: description))

        XCTAssertEqual(status.percentage, 100)
        XCTAssertTrue(status.isFullyCharged)
        XCTAssertTrue(status.isOnExternalPower)
        XCTAssertNil(status.timeRemainingMinutes, "0 分钟表示系统正在估算/已充满，不应展示")
    }

    func testBatteryParsingReturnsNilForDesktopOrMissingFields() {
        XCTAssertNil(BatteryReader.parse(description: [:]))
        // Is Present 为 false：台式机 / 电池被移除。
        XCTAssertNil(BatteryReader.parse(description: [BatteryReader.isPresentKey: NSNumber(value: false)]))
        // 缺少容量字段时不能伪造 0%。
        let incomplete: [String: Any] = [
            BatteryReader.isPresentKey: NSNumber(value: true),
            BatteryReader.currentCapacityKey: NSNumber(value: 50)
        ]
        XCTAssertNil(BatteryReader.parse(description: incomplete))
    }

    func testBatteryPercentageClampsAndRejectsZeroCapacity() {
        XCTAssertEqual(BatteryStatus.percentage(currentCapacity: 120, maxCapacity: 100), 100)
        XCTAssertEqual(BatteryStatus.percentage(currentCapacity: -5, maxCapacity: 100), 0)
        XCTAssertEqual(BatteryStatus.percentage(currentCapacity: 0, maxCapacity: 0), nil)
        XCTAssertEqual(BatteryStatus.percentage(currentCapacity: 0, maxCapacity: 100), 0)
    }

    func testBatteryTextValuesAreTolerant() throws {
        // IOKit 在不同机型上可能给出字符串形式的数值。
        let description: [String: Any] = [
            BatteryReader.isPresentKey: "true",
            BatteryReader.currentCapacityKey: "55",
            BatteryReader.maxCapacityKey: "100",
            BatteryReader.isChargingKey: "1",
            BatteryReader.isChargedKey: "0",
            BatteryReader.powerSourceStateKey: BatteryReader.acPowerValue
        ]

        let status = try XCTUnwrap(BatteryReader.parse(description: description))

        XCTAssertEqual(status.percentage, 55)
        XCTAssertTrue(status.isCharging)
    }

    // MARK: - DeepSeek balance endpoint

    func testBalanceEndpointDropsChatBasePath() throws {
        XCTAssertEqual(
            try DeepSeekBalanceClient.balanceURL(baseURL: "https://api.deepseek.com/v1").absoluteString,
            "https://api.deepseek.com/user/balance"
        )
        XCTAssertEqual(
            try DeepSeekBalanceClient.balanceURL(baseURL: "https://api.deepseek.com").absoluteString,
            "https://api.deepseek.com/user/balance"
        )
        XCTAssertEqual(
            try DeepSeekBalanceClient.balanceURL(baseURL: "http://127.0.0.1:8787/v1/").absoluteString,
            "http://127.0.0.1:8787/user/balance"
        )
    }

    func testBalanceEndpointUsesDefaultForEmptyBaseURL() throws {
        XCTAssertEqual(
            try DeepSeekBalanceClient.balanceURL(baseURL: "  ").absoluteString,
            "https://api.deepseek.com/user/balance"
        )
    }

    func testBalanceEndpointRejectsInvalidBaseURL() {
        XCTAssertThrowsError(try DeepSeekBalanceClient.balanceURL(baseURL: "api.deepseek.com")) { error in
            XCTAssertEqual(error as? DeepSeekBalanceError, .invalidBaseURL("api.deepseek.com"))
        }
        XCTAssertThrowsError(try DeepSeekBalanceClient.balanceURL(baseURL: "ftp://api.deepseek.com")) { error in
            XCTAssertNotNil(error as? DeepSeekBalanceError)
        }
    }

    // MARK: - DeepSeek balance parsing

    func testParsesOfficialBalancePayload() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "110.00",
              "granted_balance": "10.00",
              "topped_up_balance": "100.00"
            }
          ]
        }
        """
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let snapshot = try DeepSeekBalanceClient.parse(
            data: Data(json.utf8),
            statusCode: 200,
            fetchedAt: fetchedAt
        )

        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
        let primary = try XCTUnwrap(snapshot.primary)
        XCTAssertEqual(primary.currency, "CNY")
        XCTAssertEqual(primary.totalBalance, "110.00")
        XCTAssertEqual(primary.grantedBalance, "10.00")
        XCTAssertEqual(primary.toppedUpBalance, "100.00")
        XCTAssertEqual(primary.displayTotal, "¥110.00")
    }

    func testParsesNumericAmountsAndMultipleCurrencies() throws {
        let json = """
        {
          "is_available": false,
          "balance_infos": [
            {"currency": "USD", "total_balance": 5.5, "granted_balance": 0, "topped_up_balance": 5.5},
            {"currency": "CNY", "total_balance": 20, "granted_balance": 20}
          ]
        }
        """

        let snapshot = try DeepSeekBalanceClient.parse(data: Data(json.utf8), statusCode: 200)

        XCTAssertFalse(snapshot.isAvailable)
        XCTAssertEqual(snapshot.infos.count, 2)
        XCTAssertEqual(snapshot.primary?.currency, "CNY", "多币种时优先人民币")
        XCTAssertEqual(snapshot.primary?.displayTotal, "¥20")
        XCTAssertEqual(snapshot.infos.first?.displayTotal, "$5.5")
    }

    func testBalanceParseRejectsUnauthorizedAndMalformed() {
        XCTAssertThrowsError(
            try DeepSeekBalanceClient.parse(data: Data(), statusCode: 401)
        ) { error in
            XCTAssertEqual(error as? DeepSeekBalanceError, .unauthorized)
        }

        XCTAssertThrowsError(
            try DeepSeekBalanceClient.parse(data: Data("{}".utf8), statusCode: 200)
        ) { error in
            guard let balanceError = error as? DeepSeekBalanceError,
                  case .malformedResponse = balanceError else {
                return XCTFail("应返回 malformedResponse，实际：\(error)")
            }
        }

        XCTAssertThrowsError(
            try DeepSeekBalanceClient.parse(
                data: Data(#"{"is_available":true,"balance_infos":[]}"#.utf8),
                statusCode: 200
            )
        ) { error in
            guard let balanceError = error as? DeepSeekBalanceError,
                  case .malformedResponse = balanceError else {
                return XCTFail("空 balance_infos 应视为解析失败，实际：\(error)")
            }
        }
    }

    // MARK: - Provider resolution

    func testResolverPrefersDefaultDeepSeekChannel() {
        let defaultDeepSeek = makeProvider(id: "primary", kind: .deepSeek, keyReference: "key-primary")
        let otherDeepSeek = makeProvider(id: "secondary", kind: .deepSeek, keyReference: "key-secondary")

        let resolved = DeepSeekProviderResolver.resolve(
            providers: [otherDeepSeek, defaultDeepSeek],
            defaultProvider: defaultDeepSeek
        )

        XCTAssertEqual(resolved?.id, "primary")
    }

    func testResolverFallsBackToAnotherDeepSeekChannel() {
        let openAI = makeProvider(id: "openai", kind: .openAI, keyReference: "key-openai")
        let deepSeek = makeProvider(id: "deepseek", kind: .deepSeek, keyReference: "key-deepseek")

        let resolved = DeepSeekProviderResolver.resolve(
            providers: [openAI, deepSeek],
            defaultProvider: openAI
        )

        XCTAssertEqual(resolved?.id, "deepseek")
    }

    func testResolverReturnsKeylessDeepSeekChannelForConfigHint() throws {
        let deepSeek = makeProvider(id: "deepseek", kind: .deepSeek, keyReference: "")

        let resolved = try XCTUnwrap(
            DeepSeekProviderResolver.resolve(providers: [deepSeek], defaultProvider: deepSeek),
            "缺少 Key 时仍返回通道，UI 才能提示去配置"
        )
        XCTAssertEqual(resolved.id, "deepseek")
        XCTAssertFalse(resolved.hasAPIKey)
    }

    func testResolverReturnsNilWithoutDeepSeekChannel() {
        let openAI = makeProvider(id: "openai", kind: .openAI, keyReference: "key-openai")
        let ollama = makeProvider(id: "ollama", kind: .ollama, keyReference: "")

        XCTAssertNil(DeepSeekProviderResolver.resolve(providers: [openAI, ollama], defaultProvider: openAI))
    }

    private func makeProvider(
        id: String,
        kind: ProviderKind,
        keyReference: String
    ) -> AIProvider {
        AIProvider(
            id: id,
            name: kind.label,
            kind: kind,
            baseURL: kind.defaultBaseURL,
            model: kind.defaultModel,
            apiKeyReference: keyReference,
            isDefault: false
        )
    }
}
