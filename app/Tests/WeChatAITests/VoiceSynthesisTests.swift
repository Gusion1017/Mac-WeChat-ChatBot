import Foundation
import XCTest

@testable import WeChatAI

/// 出站语音合成（CosyVoice3 本地 HTTP 旁路）：
/// 文本清洗 / 超限截断 / 音色选择 / 音频重采样与 WAV 头 / 未就绪错误路径。
/// 真实服务端到端合成见 `CosyVoiceTests` 的 E2E 用例（默认跳过）。
final class VoiceSynthesisTests: XCTestCase {
    // MARK: - 1. 文本清洗

    func testSanitizeRemovesCodeMarkdownURLsAndEmoji() {
        let raw = #"""
        ## 今天安排

        这是 **重点**，先看 https://example.com/docs 和 `make build`。

        ```swift
        let x = 1
        ```

        - 第一条 😊
        - 第二条 👍🏻
        """#
        let text = VoiceTextSanitizer.sanitizeForSpeech(raw)
        XCTAssertFalse(text.contains("#"), "标题标记应去掉")
        XCTAssertFalse(text.lowercased().contains("http"), "URL 应去掉")
        XCTAssertFalse(text.contains("`"), "代码标记应去掉")
        XCTAssertFalse(text.contains("let x"), "代码块内容应去掉")
        XCTAssertFalse(text.contains("😊"), "emoji 应去掉")
        XCTAssertFalse(text.contains("👍"), "emoji 应去掉")
        XCTAssertTrue(text.contains("今天安排"))
        XCTAssertTrue(text.contains("重点"))
        XCTAssertTrue(text.contains("第一条"))
        XCTAssertTrue(text.contains("第二条"))
    }

    func testSanitizeMarkdownLinkKeepsVisibleText() {
        let text = VoiceTextSanitizer.sanitizeForSpeech("详见[开发文档](https://example.com/dev)。")
        XCTAssertEqual(text, "详见开发文档。")
    }

    func testSanitizeRemovesEmojiOnlyText() {
        XCTAssertEqual(VoiceTextSanitizer.sanitizeForSpeech("😊🎉👍🏻"), "")
        XCTAssertEqual(VoiceTextSanitizer.sanitizeForSpeech("   \n\t  "), "")
    }

    func testSanitizeCollapsesWhitespace() {
        XCTAssertEqual(
            VoiceTextSanitizer.sanitizeForSpeech("你好    世界\u{3000}呀"),
            "你好 世界 呀"
        )
    }

    func testSanitizeKeepsToneWordsAndPunctuation() {
        let text = VoiceTextSanitizer.sanitizeForSpeech("好呀～哈哈，那就这样吧！")
        XCTAssertEqual(text, "好呀～哈哈，那就这样吧！")
    }

    func testSanitizeStripsLeadingWeChatMention() {
        XCTAssertEqual(
            VoiceTextSanitizer.sanitizeForSpeech("@测试昵称 测试消息，今天怎么样？"),
            "测试消息，今天怎么样？")
        XCTAssertEqual(
            VoiceTextSanitizer.sanitizeForSpeech("@张三，你好呀。"),
            "你好呀。")
    }

    func testSanitizeConvertsPercentAndCurrencyForSpeech() {
        XCTAssertEqual(
            VoiceTextSanitizer.sanitizeForSpeech("涨了85%，预算3000块。"),
            "涨了百分之85，预算3000块。")
        XCTAssertEqual(
            VoiceTextSanitizer.sanitizeForSpeech("门票¥120，折合$20。"),
            "门票120元，折合20美元。")
    }

    func testSanitizeConvertsEmDashToComma() {
        XCTAssertEqual(
            VoiceTextSanitizer.sanitizeForSpeech("掉到线下就剩骨架——我懒。"),
            "掉到线下就剩骨架，我懒。")
    }

    func testSanitizeKeepsAbbreviationsByDefault() {
        let text = VoiceTextSanitizer.sanitizeForSpeech("PR 已经看过了，Slack 上也通知了 AI 组。")
        XCTAssertTrue(text.contains("PR"))
        XCTAssertTrue(text.contains("Slack"))
        XCTAssertTrue(text.contains("AI"))
    }

    func testSanitizeCustomAbbreviationDictionaryUsesWordBoundaries() {
        let text = VoiceTextSanitizer.sanitizeForSpeech(
            "请把 PR 发给 Slack，AIM 不要动",
            abbreviations: ["PR": "P R", "Slack": "斯莱克"]
        )
        XCTAssertTrue(text.contains("P R"))
        XCTAssertTrue(text.contains("斯莱克"))
        XCTAssertTrue(text.contains("AIM"), "不应替换单词内部的 AI")
    }

    func testSanitizeCapsVeryLongInput() {
        let text = VoiceTextSanitizer.sanitizeForSpeech(String(repeating: "啊", count: 1500))
        XCTAssertEqual(text.count, VoiceTextSanitizer.maxInputCharacters)
    }

    // MARK: - 2. 超限截断

    func testSentenceCappedKeepsWholeSentences() {
        let text = "第一句话。第二句话。第三句话。"
        XCTAssertEqual(
            VoiceTextSanitizer.sentenceCapped(text, maxCharacters: 10),
            "第一句话。第二句话。"
        )
    }

    func testSentenceCappedFallsBackToCommaForLongSentence() {
        let text = "这是一段很长的话，接下去还有内容，再后面还有内容，最后还有。"
        let capped = VoiceTextSanitizer.sentenceCapped(text, maxCharacters: 25)
        XCTAssertLessThanOrEqual(capped.count, 25)
        XCTAssertTrue(capped.hasPrefix("这是一段很长的话"))
        XCTAssertTrue(capped.hasSuffix("，"))
    }

    func testSentenceCappedHardCutsWithoutPunctuation() {
        let capped = VoiceTextSanitizer.sentenceCapped(
            String(repeating: "字", count: 50), maxCharacters: 10)
        XCTAssertEqual(capped.count, 10)
    }

    func testSentenceCappedShortTextUnchanged() {
        XCTAssertEqual(
            VoiceTextSanitizer.sentenceCapped("短句。", maxCharacters: 10), "短句。")
    }

    func testSentenceCappedZeroBudgetReturnsEmpty() {
        XCTAssertEqual(
            VoiceTextSanitizer.sentenceCapped("第一句。第二句。", maxCharacters: 0), "")
    }

    func testCharacterBudgetScalesWithMeasuredRate() {
        // 100 字读 100 秒 = 每秒 1 字；30 秒上限 × 0.9 安全系数 → 27 字。
        XCTAssertEqual(
            VoiceTextSanitizer.characterBudget(
                spokenSeconds: 100, textLength: 100, maxSeconds: 30),
            27
        )
        // 预算超过原文时收敛到「至少少 1 个字」，避免截断后与原文相同。
        XCTAssertEqual(
            VoiceTextSanitizer.characterBudget(
                spokenSeconds: 1, textLength: 10, maxSeconds: 60),
            9
        )
        XCTAssertEqual(
            VoiceTextSanitizer.characterBudget(
                spokenSeconds: 0, textLength: 10, maxSeconds: 30),
            0
        )
    }

    // MARK: - 3. 音色选择 / 输出目录

    func testVoiceSelectionUsesCosyVoiceSettings() {
        var settings = VoiceSettings()
        settings.cosyVoiceVoiceID = "  loli  "
        settings.cosyVoiceSpeed = 9
        let selection = VoiceSelection(settings: settings)
        XCTAssertEqual(selection.cosyVoiceVoiceID, "loli", "音色 ID 必须去空白")
        XCTAssertEqual(selection.trimmedVoiceID, "loli")
        XCTAssertEqual(selection.effectiveSpeed, 2.0, accuracy: 0.0001)
        XCTAssertTrue(selection.hasVoice)

        var empty = VoiceSettings()
        empty.cosyVoiceVoiceID = "   "
        empty.cosyVoiceSpeed = 0.1
        let none = VoiceSelection(settings: empty)
        XCTAssertFalse(none.hasVoice, "空白音色必须视为未选择，不能回退内置音色")
        XCTAssertEqual(none.effectiveSpeed, 0.5, accuracy: 0.0001)
    }

    func testOutputDirectoryIsUnderActiveAccountMedia() {
        // 2026-10-27：新媒体目录按微信账号隔离，TTS 输出位于当前账号 media/tts。
        let expected = AppPaths.mediaDirectory
            .appendingPathComponent("tts", isDirectory: true).path
        XCTAssertEqual(VoiceSynthesisService.outputDirectory.path, expected)
        XCTAssertTrue(
            expected.hasSuffix("/accounts/\(AccountProfile.activeID)/media/tts"),
            "TTS 目录必须位于当前账号 media 下，实际：\(expected)"
        )
    }

    func testSupportedOutputSampleRates() {
        XCTAssertTrue(VoiceSynthesisService.supportedOutputSampleRates.contains(24_000))
        XCTAssertTrue(VoiceSynthesisService.supportedOutputSampleRates.contains(16_000))
        XCTAssertFalse(VoiceSynthesisService.supportedOutputSampleRates.contains(48_000))
    }

    func testEdgeFadeAttenuatesBothEnds() {
        var samples = [Float](repeating: 1, count: 2_000)
        VoiceSynthesisService.applyEdgeFade(&samples, sampleRate: 24_000)
        XCTAssertLessThan(samples[0], 0.01)
        XCTAssertGreaterThan(samples[samples.count / 2], 0.99)
        XCTAssertLessThan(samples[samples.count - 1], 0.01)
        // 过短音频不处理。
        var tiny: [Float] = [1, 1]
        VoiceSynthesisService.applyEdgeFade(&tiny, sampleRate: 24_000)
        XCTAssertEqual(tiny, [1, 1])
    }

    // MARK: - 4. 音频（24k → 16k / WAV）

    func testResample24kTo16kProducesExpectedLength() throws {
        let sampleRate = 24_000
        let samples = (0..<sampleRate).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))) * 0.5
        }
        let output = try VoiceSynthesisAudio.resampleTo16k(samples, sampleRate: sampleRate)
        XCTAssertEqual(Double(output.count), 16_000, accuracy: 64)
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 1.0 })
    }

    func testResample16kIsPassThrough() throws {
        let samples: [Float] = [0, 0.25, -0.25, 0.5]
        XCTAssertEqual(
            try VoiceSynthesisAudio.resampleTo16k(samples, sampleRate: 16_000), samples)
    }

    func testResampleEmptyThrows() {
        XCTAssertThrowsError(try VoiceSynthesisAudio.resampleTo16k([], sampleRate: 24_000))
    }

    func testWriteWAVIs16kMono16Bit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = (0..<8_000).map { index in
            Float(sin(2 * Double.pi * 220 * Double(index) / 16_000)) * 0.4
        }
        try VoiceSynthesisAudio.writePCM16WAV(samples: samples, to: url)

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(data.count, 44)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")

        let meta = try VoiceSynthesisAudio.wavMetadata(url: url)
        XCTAssertEqual(meta.sampleRate, 16_000)
        XCTAssertEqual(meta.channels, 1)
        XCTAssertEqual(meta.bitsPerSample, 16)
        XCTAssertEqual(meta.duration, 0.5, accuracy: 0.02)
    }

    func testWriteWAVSupportsNative24k() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-wav24-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampleRate = 24_000
        let samples = (0..<12_000).map { index in
            Float(sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate))) * 0.4
        }
        try VoiceSynthesisAudio.writePCM16WAV(
            samples: samples, sampleRate: sampleRate, to: url)

        let meta = try VoiceSynthesisAudio.wavMetadata(url: url)
        XCTAssertEqual(meta.sampleRate, 24_000)
        XCTAssertEqual(meta.channels, 1)
        XCTAssertEqual(meta.bitsPerSample, 16)
        XCTAssertEqual(meta.duration, 0.5, accuracy: 0.02)
    }

    func testDecodeMono16kRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-decode-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = (0..<8_000).map { index in
            Float(sin(2 * Double.pi * 330 * Double(index) / 16_000)) * 0.3
        }
        try VoiceSynthesisAudio.writePCM16WAV(samples: samples, to: url)
        let decoded = try VoiceSynthesisAudio.decodeMono16k(url: url)
        XCTAssertEqual(Double(decoded.count), 8_000, accuracy: 64)
    }

    func testDecodeMono16kHonorsMaxSeconds() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-trim-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = (0..<16_000).map { index in
            Float(sin(2 * Double.pi * 330 * Double(index) / 16_000)) * 0.3
        }
        try VoiceSynthesisAudio.writePCM16WAV(samples: samples, to: url)
        let decoded = try VoiceSynthesisAudio.decodeMono16k(url: url, maxSeconds: 0.5)
        XCTAssertEqual(Double(decoded.count), 8_000, accuracy: 64)
    }

    // MARK: - 5. 服务错误路径

    func testEmptyTextThrowsEmptyText() async {
        let service = VoiceSynthesisService()
        do {
            _ = try await service.synthesize(
                text: "  😊🎉  ", voice: VoiceSelection(), maxSeconds: 30)
            XCTFail("清洗后为空应抛错")
        } catch let error as VoiceSynthesisError {
            XCTAssertEqual(error, .emptyText)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testEngineNotReadyWhenVoiceNotSelected() async {
        // 未选择音色时在发 HTTP 请求之前就应明确报错（App 不内置任何音色）。
        let service = VoiceSynthesisService()
        let voice = VoiceSelection(cosyVoiceVoiceID: "   ", speed: 1.0)
        do {
            _ = try await service.synthesize(
                text: "测试一句话。", voice: voice, maxSeconds: 30)
            XCTFail("未选择音色时应抛 engineNotReady")
        } catch let error as VoiceSynthesisError {
            guard case .engineNotReady(let reason) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertTrue(reason.contains("未选择"), "错误原因应说明未选择音色：\(reason)")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }
}
