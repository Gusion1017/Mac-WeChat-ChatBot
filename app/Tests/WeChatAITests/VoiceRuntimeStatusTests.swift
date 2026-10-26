import XCTest
@testable import WeChatAI

/// 2026-10-26：语音发送运行时状态（倒计时/句柄）解析与决策门禁。
final class VoiceRuntimeStatusTests: XCTestCase {
    func testParsesWarmupStatusAndCountsDownLocally() throws {
        let json = """
        {"ok":true,"configured":true,"hook":{"mode":"r3","voiceSend":true,
        "textSeed":true,"voiceSeed":true,"cdnReady":true,"loginSettled":false,
        "warmupRemainingMs":60000,"voiceReady":false}}
        """
        let status = try OneBotClient.parseVoiceStatus(data: Data(json.utf8), statusCode: 200)
        XCTAssertTrue(status.available)
        XCTAssertTrue(status.configured)
        XCTAssertTrue(status.textSeed)
        XCTAssertTrue(status.voiceSeed)
        XCTAssertFalse(status.loginSettled)
        XCTAssertFalse(status.canSendVoice())
        XCTAssertEqual(status.remainingWarmupSeconds(now: status.receivedAt), 60)
        XCTAssertEqual(
            status.remainingWarmupSeconds(now: status.receivedAt.addingTimeInterval(15)),
            45
        )
        XCTAssertFalse(status.canSendVoice(now: status.receivedAt.addingTimeInterval(59)))
        // 快照里的 loginSettled/voiceReady 仍为 false；倒计时结束也必须重新查询 bridge，
        // 不能只靠本地时间把状态“猜”成就绪。
        XCTAssertFalse(status.canSendVoice(now: status.receivedAt.addingTimeInterval(61)))
    }

    func testParsesMissingHandles() throws {
        let json = """
        {"ok":true,"configured":true,"hook":{"voiceSend":true,"textSeed":true,
        "voiceSeed":false,"loginSettled":true,"warmupRemainingMs":0,"voiceReady":false}}
        """
        let status = try OneBotClient.parseVoiceStatus(data: Data(json.utf8), statusCode: 200)
        XCTAssertFalse(status.canSendVoice())
        XCTAssertTrue(status.summary().contains("语音句柄"))
    }

    func testParsesUnavailableStatus() throws {
        let json = """
        {"ok":false,"configured":false,"error":"hook 不可用"}
        """
        let status = try OneBotClient.parseVoiceStatus(data: Data(json.utf8), statusCode: 200)
        XCTAssertFalse(status.available)
        XCTAssertFalse(status.canSendVoice())
        XCTAssertEqual(status.summary(), "hook 不可用")
    }

    func testRuntimeGateBlocksVoiceDecision() {
        var settings = VoiceSettings()
        settings.replyEnabled = true
        settings.replyProbability = 1
        let decision = decideVoiceReply(VoiceReplyContext(
            global: settings,
            incomingWasVoice: true,
            replyText: "好的",
            modelsReady: true,
            runtimeReady: false,
            rng: 0
        ))
        XCTAssertEqual(decision, .text(reason: "语音发送句柄未就绪或仍在启动倒计时"))
    }

    func testStartupHandlePromptPolicy() {
        let missingVoiceSeed = VoiceRuntimeStatus(
            available: true,
            configured: true,
            voiceSend: true,
            textSeed: true,
            voiceSeed: false,
            cdnReady: true,
            loginSettled: true,
            warmupRemainingMs: 0,
            voiceReady: false,
            error: nil,
            receivedAt: Date()
        )
        XCTAssertTrue(missingVoiceSeed.needsHandleCapturePromptOnStartup)

        var warmupOnly = missingVoiceSeed
        warmupOnly.textSeed = true
        warmupOnly.voiceSeed = true
        warmupOnly.loginSettled = false
        warmupOnly.warmupRemainingMs = 30_000
        warmupOnly.voiceReady = false
        XCTAssertFalse(warmupOnly.needsHandleCapturePromptOnStartup, "仅登录预热不应弹句柄引导")

        var bridgeDown = missingVoiceSeed
        bridgeDown.available = false
        XCTAssertFalse(bridgeDown.needsHandleCapturePromptOnStartup)

        var r3Off = missingVoiceSeed
        r3Off.configured = false
        XCTAssertFalse(r3Off.needsHandleCapturePromptOnStartup, "R3 未启用时捕获句柄也无效")
    }

    func testVoiceStatusRequestUsesBearerToken() throws {
        let base = URL(string: "http://127.0.0.1:58080")!
        let request = try OneBotClient.voiceStatusRequest(baseURL: base, token: "test-token")
        XCTAssertEqual(request.url?.path, "/voice_status")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }
}
