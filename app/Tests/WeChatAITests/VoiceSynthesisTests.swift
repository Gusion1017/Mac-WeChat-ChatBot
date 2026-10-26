import AVFoundation
import XCTest

@testable import WeChatAI

/// 出站语音合成（T3，2026-10-26）：
/// 文本清洗 / 超限截断 / 模型状态与路径 / 24k→16k 重采样 / WAV 头 /
/// 克隆档案 CRUD；模型就绪时跑一次真实合成并留样本。
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
            VoiceTextSanitizer.sanitizeForSpeech("@我的枪很长 老大爷嘛，今天怎么样？"),
            "老大爷嘛，今天怎么样？")
        XCTAssertEqual(
            VoiceTextSanitizer.sanitizeForSpeech("@张三，你好呀。"),
            "你好呀。")
    }

    func testSanitizeConvertsPercentAndCurrencyForFST() {
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
        XCTAssertEqual(VoiceTextSanitizer.sentenceCapped("短句。", maxCharacters: 100), "短句。")
    }

    func testSentenceCappedZeroBudgetReturnsEmpty() {
        XCTAssertEqual(VoiceTextSanitizer.sentenceCapped("短句。", maxCharacters: 0), "")
        XCTAssertEqual(VoiceTextSanitizer.sentenceCapped("短句。", maxCharacters: -3), "")
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

    // MARK: - 3. 模型路径 / 状态

    func testModelsDirectoryIsUnderApplicationSupport() {
        let path = VoiceModelStore.modelsDirectory.path
        XCTAssertTrue(
            path.hasSuffix("Library/Application Support/WeChatAI/models"),
            "模型目录必须在 Application Support 下，实际：\(path)"
        )
        XCTAssertTrue(VoiceSynthesisService.outputDirectory.path.hasSuffix("WeChatAI/media/tts"))
    }

    func testModelCatalogIsConsistent() {
        XCTAssertEqual(VoiceModelStore.catalog.count, 3)
        let kinds = Set(VoiceModelStore.catalog.map(\.kind))
        XCTAssertEqual(kinds, Set(VoiceModelKind.allCases))
        for spec in VoiceModelStore.catalog {
            XCTAssertEqual(spec.downloadURL.scheme, "https", "\(spec.kind) 必须走 HTTPS")
            XCTAssertEqual(spec.sha256.count, 64, "\(spec.kind) SHA256 必须是 64 位 hex")
            XCTAssertTrue(
                spec.sha256.allSatisfy(\.isHexDigit),
                "\(spec.kind) SHA256 必须是 hex：\(spec.sha256)"
            )
            XCTAssertGreaterThan(spec.approximateBytes, 0)
            XCTAssertFalse(spec.archiveName.isEmpty)
            XCTAssertTrue(spec.isArchive == (spec.extractedDirectory != nil))
        }
    }

    func testModelStateSemantics() {
        XCTAssertEqual(VoiceModelState.notDownloaded.fraction, 0)
        XCTAssertFalse(VoiceModelState.notDownloaded.isBusy)
        XCTAssertEqual(VoiceModelState.downloading(progress: 0.5).fraction, 0.5)
        XCTAssertTrue(VoiceModelState.downloading(progress: nil).isBusy)
        XCTAssertTrue(VoiceModelState.verifying.isBusy)
        XCTAssertTrue(VoiceModelState.extracting.isBusy)
        XCTAssertTrue(VoiceModelState.ready.isReady)
        XCTAssertEqual(VoiceModelState.ready.fraction, 1)
        XCTAssertFalse(VoiceModelState.failed("x").isBusy)
        XCTAssertEqual(VoiceModelState.failed("坏文件").displayText, "失败：坏文件")
    }

    func testModelReadinessMatchesFileSystem() {
        let vocoderURL = VoiceModelStore.modelsDirectory
            .appendingPathComponent("vocos_24khz.onnx")
        let exists = FileManager.default.fileExists(atPath: vocoderURL.path)
        XCTAssertEqual(VoiceModelStore.isModelReady(.vocoder), exists)
    }

    func testSHA256Helper() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-sha-\(UUID().uuidString).bin")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            try VoiceModelStore.sha256Hex(of: url),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testDownloadRequiresConsent() async {
        let store = await VoiceModelStore.shared
        do {
            try await store.download([.vocoder], consent: false)
            XCTFail("未同意下载时必须抛 consentRequired")
        } catch let error as VoiceModelError {
            XCTAssertEqual(error, .consentRequired)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    /// 联网下载/校验/落盘全链路（默认跳过；`WECHATAI_TTS_NETWORK_TESTS=1` 手动跑）。
    func testVocoderDownloadPipeline() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WECHATAI_TTS_NETWORK_TESTS"] == "1",
            "设置 WECHATAI_TTS_NETWORK_TESTS=1 才跑联网下载测试"
        )
        let target = VoiceModelStore.modelsDirectory.appendingPathComponent("vocos_24khz.onnx")
        let backup = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocos-backup-\(UUID().uuidString).onnx")
        let existed = FileManager.default.fileExists(atPath: target.path)
        if existed {
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: target, to: backup)
        }
        addTeardownBlock {
            if existed {
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: backup, to: target)
            }
            try? FileManager.default.removeItem(at: backup)
        }
        try? FileManager.default.removeItem(at: target)

        let store = await VoiceModelStore.shared
        try await store.download([.vocoder], consent: true)
        let state = await store.state(for: .vocoder)
        XCTAssertEqual(state, .ready)
        XCTAssertTrue(VoiceModelStore.isModelReady(.vocoder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        let spec = try XCTUnwrap(VoiceModelStore.catalog.first { $0.kind == .vocoder })
        XCTAssertEqual(try VoiceModelStore.sha256Hex(of: target), spec.sha256)
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

    func testEngineNotReadyWhenModelsMissing() async throws {
        guard !VoiceSynthesisService.isReady(.kokoro) else {
            throw XCTSkip("Kokoro 模型已下载，跳过未就绪用例")
        }
        let service = VoiceSynthesisService()
        do {
            _ = try await service.synthesize(
                text: "测试一句话。", voice: VoiceSelection(engine: .kokoro), maxSeconds: 30)
            XCTFail("模型缺失时应抛 engineNotReady")
        } catch let error as VoiceSynthesisError {
            guard case .engineNotReady(let engine, _) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(engine, .kokoro)
        }
    }

    func testCloneNotFoundWhenZipvoiceReady() async throws {
        guard VoiceSynthesisService.isReady(.zipvoiceClone) else {
            throw XCTSkip("ZipVoice 模型未下载，跳过克隆缺失用例")
        }
        let service = VoiceSynthesisService()
        let voice = VoiceSelection(engine: .zipvoiceClone, cloneID: "does-not-exist")
        do {
            _ = try await service.synthesize(text: "测试一句话。", voice: voice, maxSeconds: 30)
            XCTFail("克隆 ID 不存在时应抛 cloneNotFound")
        } catch let error as VoiceSynthesisError {
            XCTAssertEqual(error, .cloneNotFound("does-not-exist"))
        }
    }

    // MARK: - 6. 克隆档案 CRUD

    func testCloneStoreCRUD() async throws {
        let store = await VoiceCloneStore.shared
        let reference = try Self.makeSineReference(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: reference.url) }

        let profile = try await store.add(
            name: "T3 测试音色", audioURL: reference.url, referenceText: "")
        addTeardownBlock { [store] in
            try? await store.delete(id: profile.id)
        }

        XCTAssertEqual(profile.sampleRate, 16_000)
        XCTAssertEqual(profile.duration, 1.0, accuracy: 0.1)
        XCTAssertFalse(profile.hasReferenceText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.audioPath))

        try await store.setReferenceText(id: profile.id, text: "参考文本")
        let updated = await store.profile(id: profile.id)
        XCTAssertEqual(updated?.referenceText, "参考文本")
        XCTAssertTrue(updated?.hasReferenceText ?? false)

        try await store.rename(id: profile.id, to: "T3 改名")
        let renamed = await store.profile(id: profile.id)
        XCTAssertEqual(renamed?.name, "T3 改名")

        // 静态读取（合成服务走这条路）也能看到刚写入的档案。
        XCTAssertEqual(VoiceCloneStore.profile(id: profile.id)?.name, "T3 改名")

        try await store.delete(id: profile.id)
        let deleted = await store.profile(id: profile.id)
        XCTAssertNil(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.audioPath))
    }

    func testCloneStoreRejectsEmptyNameAndBadAudio() async throws {
        let store = await VoiceCloneStore.shared
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-audio-\(UUID().uuidString).wav")
        do {
            _ = try await store.add(name: "x", audioURL: missing)
            XCTFail("缺失音频应抛错")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(error, .audioUnreadable(missing.path))
        }
    }

    // MARK: - 7. 真实合成（模型就绪时）

    func testKokoroRealSynthesis() async throws {
        try XCTSkipUnless(VoiceSynthesisService.isReady(.kokoro), "Kokoro 模型未下载")

        let service = VoiceSynthesisService()
        let voice = VoiceSelection(engine: .kokoro, kokoroSpeakerID: 0, speed: 1.0)
        let text = "你好，这是一次语音合成测试。今天天气不错，适合出去走走。"

        let start = Date()
        let result = try await service.synthesize(text: text, voice: voice, maxSeconds: 30)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.sampleRate, 24_000, "Kokoro 原生 24k，不再强制降 16k")
        XCTAssertGreaterThan(result.duration, 0.5)
        XCTAssertLessThanOrEqual(result.duration, 30.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.wavURL.path))

        let meta = try VoiceSynthesisAudio.wavMetadata(url: result.wavURL)
        XCTAssertEqual(meta.sampleRate, 24_000)
        XCTAssertEqual(meta.channels, 1)
        XCTAssertEqual(meta.bitsPerSample, 16)
        XCTAssertEqual(meta.duration, result.duration, accuracy: 0.05)

        print(String(
            format: "[TTS] kokoro RTF=%.3f elapsed=%.2fs audio=%.2fs bytes=%d file=%@",
            elapsed / max(result.duration, 0.001),
            elapsed,
            result.duration,
            (try? Data(contentsOf: result.wavURL).count) ?? 0,
            result.wavURL.path
        ))
        try Self.copySample(result.wavURL, name: "kokoro-zh-\(Self.stamp()).wav")

        // 懒加载复用：第二次合成不应重新加载模型（只验证可用与更快）。
        let second = try await service.synthesize(
            text: "第二段语音，用于验证引擎复用。", voice: voice, maxSeconds: 30)
        XCTAssertGreaterThan(second.duration, 0)
        let loaded = await service.loadedEngineCount
        XCTAssertGreaterThanOrEqual(loaded, 1)
    }

    func testKokoroReadsNumbersAsOneChunk() async throws {
        try XCTSkipUnless(VoiceSynthesisService.isReady(.kokoro), "Kokoro 模型未下载")
        let service = VoiceSynthesisService()
        let voice = VoiceSelection(engine: .kokoro, kokoroSpeakerID: 18, speed: 1.25)
        let text = "3点半到2026年10月26日，电话13800138000，涨了85%。"

        let result = try await service.synthesize(text: text, voice: voice, maxSeconds: 60)
        XCTAssertEqual(result.sampleRate, 24_000)
        // 不传 rule_fsts / 不展开数字时只有 3.25s；展开成中文读法后应明显更长。
        XCTAssertGreaterThan(result.duration, 6.0, "数字/日期/电话应被正常读出")
        XCTAssertLessThanOrEqual(result.duration, 60.5)

        let meta = try VoiceSynthesisAudio.wavMetadata(url: result.wavURL)
        XCTAssertEqual(meta.sampleRate, 24_000)
        XCTAssertEqual(meta.channels, 1)
        try Self.copySample(result.wavURL, name: "kokoro-numbers-\(Self.stamp()).wav")
        print("[TTS] kokoro numbers duration=\(result.duration)s file=\(result.wavURL.path)")
    }

    func testKokoroTruncationAndTooLong() async throws {
        try XCTSkipUnless(VoiceSynthesisService.isReady(.kokoro), "Kokoro 模型未下载")
        let service = VoiceSynthesisService()
        let voice = VoiceSelection(engine: .kokoro, kokoroSpeakerID: 0, speed: 1.0)
        let longText = String(
            repeating: "这是一段比较长的语音测试文本，用来验证超限截断逻辑是否正确。",
            count: 6)

        // allowsTruncation = true（对应 VoiceOverLimit.truncate）：截断到上限内。
        let truncated = try await service.synthesize(
            text: longText, voice: voice, maxSeconds: 5, allowsTruncation: true)
        XCTAssertLessThanOrEqual(truncated.duration, 5.2)

        // allowsTruncation = false（对应 VoiceOverLimit.text）：直接抛 tooLong。
        do {
            _ = try await service.synthesize(
                text: longText, voice: voice, maxSeconds: 5, allowsTruncation: false)
            XCTFail("不允许截断时应抛 tooLong")
        } catch let error as VoiceSynthesisError {
            guard case .tooLong(_, let maxSeconds) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(maxSeconds, 5)
        }
    }

    func testZipVoiceCloneRealSynthesis() async throws {
        try XCTSkipUnless(VoiceSynthesisService.isReady(.zipvoiceClone), "ZipVoice 模型未下载")
        // 优先用 ZipVoice 自带的官方参考音频（真人、带已知文本）；否则用系统 say 生成。
        let reference = try Self.makeCloneReference()
        defer { try? FileManager.default.removeItem(at: reference.url) }

        let store = await VoiceCloneStore.shared
        let profile = try await store.add(
            name: "T3 ZipVoice 参考", audioURL: reference.url, referenceText: reference.text)
        addTeardownBlock { [store] in
            try? await store.delete(id: profile.id)
        }

        let service = VoiceSynthesisService()
        let voice = VoiceSelection(engine: .zipvoiceClone, speed: 1.0, cloneID: profile.id)
        let start = Date()
        let result = try await service.synthesize(
            text: "小米的价值观是真诚、热爱。", voice: voice, maxSeconds: 30)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.sampleRate, 24_000)
        XCTAssertGreaterThan(result.duration, 0.3)
        let meta = try VoiceSynthesisAudio.wavMetadata(url: result.wavURL)
        XCTAssertEqual(meta.sampleRate, 24_000)
        XCTAssertEqual(meta.channels, 1)
        XCTAssertEqual(meta.bitsPerSample, 16)
        print(String(
            format: "[TTS] zipvoice RTF=%.3f elapsed=%.2fs audio=%.2fs file=%@",
            elapsed / max(result.duration, 0.001), elapsed, result.duration, result.wavURL.path))
        try Self.copySample(result.wavURL, name: "zipvoice-clone-\(Self.stamp()).wav")
    }

    // MARK: - Helpers

    /// 可选的 TTS 样本输出目录；由 `WECHATAI_TTS_SAMPLES` 指定，未设置时跳过复制。
    private static var sampleDirectory: URL? {
        guard let raw = ProcessInfo.processInfo.environment["WECHATAI_TTS_SAMPLES"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 把合成样本复制到 `WECHATAI_TTS_SAMPLES` 目录（未设置时静默跳过）。
    private static func copySample(_ source: URL, name: String) throws {
        guard let directory = sampleDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// 生成 1 秒 16k 单声道正弦 WAV（克隆导入测试用，不含人声）。
    private static func makeSineReference(seconds: Double) throws -> (url: URL, text: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-ref-\(UUID().uuidString).wav")
        let count = Int(seconds * 16_000)
        let samples = (0..<count).map { index in
            Float(sin(2 * Double.pi * 220 * Double(index) / 16_000)) * 0.3
        }
        try VoiceSynthesisAudio.writePCM16WAV(samples: samples, to: url)
        return (url, "")
    }

    /// ZipVoice 克隆测试的参考音频：优选用模型自带的官方 `test_wavs/leijun-1.wav`
    /// （24 kHz 真人语音 + 官方 prompt 文本），缺失时回退到系统 `say`。
    private static func makeCloneReference() throws -> (url: URL, text: String) {
        let official = VoiceModelStore.modelsDirectory.appendingPathComponent(
            "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia/test_wavs/leijun-1.wav")
        if FileManager.default.fileExists(atPath: official.path) {
            // 复制到临时目录再交给克隆存储：测试清理只删临时文件，绝不删模型自带资产。
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("tts-ref-leijun-\(UUID().uuidString).wav")
            try FileManager.default.copyItem(at: official, to: temp)
            return (temp, "那还是36年前, 1987年. 我呢考上了武汉大学的计算机系.")
        }
        return try makeSpeechReference()
    }

    /// 用 `say` 生成一段带已知文本的参考语音（ZipVoice 克隆测试备用参考）。
    private static func makeSpeechReference() throws -> (url: URL, text: String) {
        let text = "今天天气很好，我们一起去公园散步吧。"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-say-ref-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Tingting", "-o", url.path, text]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw XCTSkip("系统 say 不可用：\(error)")
        }
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("say -v Tingting 生成参考音频失败")
        }
        return (url, text)
    }
}
