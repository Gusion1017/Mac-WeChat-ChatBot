import Foundation
import XCTest

@testable import WeChatAI

/// CosyVoice3 App 侧集成（2026-10-27）：
/// - `VoiceSettings` 的 Codable 兼容（旧 JSON 缺键走默认、已移除的引擎键被忽略）；
/// - `CosyVoiceClient` 的 health/voices/tts（URLProtocol 注入）与 WAV 解码；
/// - 安装器 `PROGRESS` 解析、安装/取消/删除状态机（本地 fake 脚本 + 临时目录）；
/// - 启动器健康轮询（注入 fake 时钟/探测/进程）与引擎可用性判定。
final class CosyVoiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FakeCosyVoiceURLProtocol.reset()
    }

    override func tearDown() {
        FakeCosyVoiceURLProtocol.reset()
        unsetenv(CosyVoiceInstallation.installScriptEnvironmentKey)
        unsetenv(CosyVoiceInstallation.homeEnvironmentKey)
        super.tearDown()
    }

    // MARK: - 1. Codable 兼容

    func testVoiceSettingsDefaultsIncludeCosyVoiceFields() {
        let settings = VoiceSettings()
        // App 不内置任何音色：默认不选 girl。
        XCTAssertEqual(settings.cosyVoiceVoiceID, "")
        XCTAssertEqual(settings.effectiveCosyVoiceVoiceID, "")
        XCTAssertFalse(settings.hasCosyVoiceVoice)
        XCTAssertEqual(settings.cosyVoiceEndpoint, "http://127.0.0.1:5051")
        XCTAssertTrue(settings.cosyVoiceAutoStart)
        XCTAssertEqual(settings.cosyVoiceSpeed, 1.0, accuracy: 0.0001)
        XCTAssertEqual(settings.effectiveCosyVoiceSpeed, 1.0, accuracy: 0.0001)
        XCTAssertEqual(settings.effectiveCosyVoiceEndpoint.absoluteString, "http://127.0.0.1:5051")
        // 语音回复默认跳过拟人化延迟。
        XCTAssertTrue(settings.skipHumanizeDelayForVoiceReply)
    }

    func testLegacyVoiceSettingsJSONWithoutNewKeysUsesDefaults() throws {
        // 旧 config.json 的 voice 段：只有 Kokoro/ZipVoice/引擎选择相关的键，
        // 没有 cosyVoice*。这些键已随引擎移除：解码时忽略，重新编码时不再写回。
        let json = """
        {
          "engine": "kokoro",
          "kokoroSpeakerID": 7,
          "kokoroSpeed": 1.5,
          "cloneID": "old-clone",
          "modelDownloadConsent": true,
          "replyEnabled": true,
          "replyProbability": 0.4
        }
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: json)
        XCTAssertTrue(settings.replyEnabled)
        XCTAssertEqual(settings.replyProbability, 0.4, accuracy: 0.0001)
        XCTAssertEqual(settings.cosyVoiceVoiceID, "", "旧配置缺键时不能默认 girl")
        XCTAssertEqual(settings.effectiveCosyVoiceVoiceID, "")
        XCTAssertEqual(settings.cosyVoiceEndpoint, "http://127.0.0.1:5051")
        XCTAssertTrue(settings.cosyVoiceAutoStart)
        XCTAssertEqual(settings.cosyVoiceSpeed, 1.0, accuracy: 0.0001)
        XCTAssertTrue(settings.skipHumanizeDelayForVoiceReply, "旧配置缺键时默认跳过拟人化延迟")

        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for removedKey in ["engine", "kokoroSpeakerID", "kokoroSpeed", "cloneID",
                           "modelDownloadConsent"] {
            XCTAssertNil(object[removedKey], "已移除的配置键不应再写入：\(removedKey)")
        }
    }

    func testCosyVoiceSettingsRoundTripAndClamp() throws {
        let json = """
        {
          "engine": "cosyvoice",
          "cosyVoiceVoiceID": "  loli  ",
          "cosyVoiceEndpoint": "127.0.0.1:6060",
          "cosyVoiceAutoStart": false,
          "cosyVoiceSpeed": 9.5
        }
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: json)
        XCTAssertEqual(settings.cosyVoiceVoiceID, "loli")
        XCTAssertEqual(settings.effectiveCosyVoiceVoiceID, "loli")
        XCTAssertEqual(settings.cosyVoiceSpeed, 2.0, accuracy: 0.0001, "语速必须收敛到 0.5–2.0")
        XCTAssertFalse(settings.cosyVoiceAutoStart)
        XCTAssertTrue(settings.hasValidCosyVoiceEndpoint)
        XCTAssertEqual(settings.effectiveCosyVoiceEndpoint.absoluteString, "http://127.0.0.1:6060")

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: encoded)
        XCTAssertEqual(decoded.effectiveCosyVoiceVoiceID, "loli")
        XCTAssertEqual(decoded.effectiveCosyVoiceEndpoint.absoluteString, "http://127.0.0.1:6060")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["engine"], "引擎选择已移除，不再写入")
        XCTAssertNotNil(object["cosyVoiceVoiceID"])
        XCTAssertNotNil(object["cosyVoiceEndpoint"])
        XCTAssertEqual(object["cosyVoiceAutoStart"] as? Bool, false)
    }

    func testLegacyEngineValuesAreIgnored() throws {
        // 历史引擎值（kokoro / zipvoiceClone / cosyvoice / 未知值）不再有对应类型：
        // 解码时忽略该键，CosyVoice3 是唯一引擎。
        for legacy in ["kokoro", "zipvoiceClone", "cosyvoice", "whisper-tts"] {
            let json = Data(#"{"engine":"\#(legacy)","cosyVoiceVoiceID":"loli"}"#.utf8)
            let settings = try JSONDecoder().decode(VoiceSettings.self, from: json)
            XCTAssertEqual(settings.cosyVoiceVoiceID, "loli", "legacy=\(legacy)")
            XCTAssertEqual(settings.effectiveCosyVoiceVoiceID, "loli", "legacy=\(legacy)")
        }
    }

    func testInvalidCosyVoiceEndpointFallsBackToDefault() {
        var settings = VoiceSettings()
        settings.cosyVoiceEndpoint = "ftp://example.com/tts"
        XCTAssertFalse(settings.hasValidCosyVoiceEndpoint)
        XCTAssertEqual(settings.effectiveCosyVoiceEndpoint.absoluteString, "http://127.0.0.1:5051")

        settings.cosyVoiceEndpoint = "   "
        XCTAssertFalse(settings.hasValidCosyVoiceEndpoint)
        XCTAssertEqual(settings.effectiveCosyVoiceEndpoint.absoluteString, "http://127.0.0.1:5051")

        // 远程 host 一律视为无效（回退默认回环地址，避免文本被发到外网）。
        settings.cosyVoiceEndpoint = "http://example.com:5051"
        XCTAssertFalse(settings.hasValidCosyVoiceEndpoint)
        XCTAssertEqual(settings.effectiveCosyVoiceEndpoint.absoluteString, "http://127.0.0.1:5051")
    }

    func testEndpointNormalization() {
        XCTAssertEqual(
            CosyVoiceClient.normalizedEndpoint("127.0.0.1:5051")?.absoluteString,
            "http://127.0.0.1:5051")
        XCTAssertEqual(
            CosyVoiceClient.normalizedEndpoint(" http://127.0.0.1:5051/ ")?.absoluteString,
            "http://127.0.0.1:5051/")
        XCTAssertEqual(
            CosyVoiceClient.normalizedEndpoint("http://localhost:5051")?.host,
            "localhost")
        XCTAssertEqual(
            CosyVoiceClient.normalizedEndpoint("http://[::1]:5051")?.host,
            "::1")
        XCTAssertNil(CosyVoiceClient.normalizedEndpoint(""))
        XCTAssertNil(CosyVoiceClient.normalizedEndpoint("ftp://host:21"))
        XCTAssertNil(CosyVoiceClient.normalizedEndpoint("http://"))
        // 文本不出设备：只允许本机回环 host。
        XCTAssertNil(CosyVoiceClient.normalizedEndpoint("http://example.com:5051"))
        XCTAssertNil(CosyVoiceClient.normalizedEndpoint("http://192.168.1.2:5051"))
        XCTAssertNil(CosyVoiceClient.normalizedEndpoint("evil.local:5051"))
    }

    // MARK: - 2. 音色目录 / 回退计划

    func testVoiceCatalogMergesRemoteVoicesInFixedOrder() {
        let remote = [
            CosyVoiceVoice(id: "onee", name: "御姐(自定义)", description: "成熟"),
            CosyVoiceVoice(id: "girl", name: "少女", description: ""),
            CosyVoiceVoice(id: "custom", name: "客服", description: "新音色"),
        ]
        let merged = CosyVoiceVoiceCatalog.merged(remote: remote)
        // remote 没有 loli：按分发边界不能补出来。
        XCTAssertEqual(merged.map(\.id), ["girl", "onee", "custom"])
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        XCTAssertEqual(byID["girl"]?.description, "清甜少女音，本机参考音",
                       "服务端空简介保留本地兜底")
        XCTAssertEqual(byID["onee"]?.name, "御姐(自定义)")
        XCTAssertEqual(byID["custom"]?.name, "客服")

        // 分发边界：输入里没有的音色不能凭空补出来。
        XCTAssertTrue(CosyVoiceVoiceCatalog.merged(remote: []).isEmpty)
        let onlyCustom = CosyVoiceVoiceCatalog.merged(remote: [
            CosyVoiceVoice(id: "custom-a", name: "客服"),
        ])
        XCTAssertEqual(onlyCustom.map(\.id), ["custom-a"], "不能自动补 girl/loli/onee")
        XCTAssertFalse(CosyVoiceVoiceCatalog.canStartService(with: []))
        XCTAssertTrue(CosyVoiceVoiceCatalog.canStartService(with: onlyCustom))
        XCTAssertEqual(CosyVoiceVoiceCatalog.resolvedVoiceID("  "), "")
        XCTAssertEqual(CosyVoiceVoiceCatalog.resolvedVoiceID(nil), "")
        XCTAssertEqual(CosyVoiceVoiceCatalog.resolvedVoiceID("loli"), "loli")
        XCTAssertEqual(CosyVoiceVoiceCatalog.displayName(for: "onee"), "御姐")
        XCTAssertEqual(CosyVoiceVoiceCatalog.displayName(for: "custom"), "custom")
    }

    func testVoiceVoiceListToleratesBadEntries() throws {
        let json = """
        {"voices":[
          {"id":"girl","name":"少女","description":"甜"},
          {"name":"没有 id"},
          {"id":"loli","name":"萝莉"},
          {"id":"onee","name":"御姐","description":"成熟"}
        ]}
        """.data(using: .utf8)!
        let list = try JSONDecoder().decode(CosyVoiceVoiceList.self, from: json)
        XCTAssertEqual(list.voices.map(\.id), ["girl", "loli", "onee"])
        XCTAssertEqual(list.voices[1].description, "")
    }

    func testVoiceEngineAvailability() {
        // CosyVoice3 是唯一引擎：安装 + 服务就绪 + 已选音色才可合成，否则直接改发文字。
        XCTAssertTrue(
            VoiceEngineAvailability.canSynthesize(
                cosyVoiceInstalled: true,
                cosyVoiceServiceReady: true,
                hasVoice: true))
        XCTAssertFalse(
            VoiceEngineAvailability.canSynthesize(
                cosyVoiceInstalled: false,
                cosyVoiceServiceReady: true,
                hasVoice: true))
        XCTAssertFalse(
            VoiceEngineAvailability.canSynthesize(
                cosyVoiceInstalled: true,
                cosyVoiceServiceReady: false,
                hasVoice: true))
        XCTAssertFalse(
            VoiceEngineAvailability.canSynthesize(
                cosyVoiceInstalled: true,
                cosyVoiceServiceReady: true,
                hasVoice: false))
    }

    func testDecideVoiceReplyUsesModelsReady() {
        var settings = VoiceSettings()
        settings.replyEnabled = true
        settings.replyProbability = 1
        settings.shortReplyOnly = false
        let base = VoiceReplyContext(
            global: settings, incomingWasVoice: false,
            replyText: "你好呀", modelsReady: false, rng: 0)
        XCTAssertFalse(decideVoiceReply(base).isVoice)
        var ready = base
        ready.modelsReady = true
        XCTAssertTrue(decideVoiceReply(ready).isVoice)
    }

    // MARK: - 3. Client（URLProtocol 注入）

    func testHealthSuccessParsesServiceInfo() async throws {
        let healthJSON = """
        {"ok":true,"ready":true,"model":"Fun-CosyVoice3-0.5B-2512",
         "sample_rate":24000,"voices":["girl","loli","onee"],
         "voices_detail":[{"id":"girl","name":"少女"}],
         "device":"mps","rtf_estimate":0.8,"loading":false}
        """.data(using: .utf8)!
        FakeCosyVoiceURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/health")
            XCTAssertEqual(request.httpMethod, "GET")
            return .http(status: 200, body: healthJSON, headers: ["Content-Type": "application/json"])
        }
        let client = makeClient()
        let health = try await client.health()
        XCTAssertTrue(health.isReady)
        XCTAssertEqual(health.model, "Fun-CosyVoice3-0.5B-2512")
        XCTAssertEqual(health.sampleRate, 24_000)
        XCTAssertEqual(health.voices, ["girl", "loli", "onee"])
        XCTAssertEqual(health.voicesDetail.first?.name, "少女")
        XCTAssertEqual(health.device, "mps")
        XCTAssertEqual(health.rtfEstimate ?? 0, 0.8, accuracy: 0.0001)
    }

    func testHealthLoadingThrowsServiceLoading() async {
        let loading = """
        {"ok":false,"loading":true,"progress":"loading model"}
        """.data(using: .utf8)!
        FakeCosyVoiceURLProtocol.setHandler { _ in
            .http(status: 503, body: loading, headers: ["Content-Type": "application/json"])
        }
        let client = makeClient()
        do {
            _ = try await client.health()
            XCTFail("503 loading 应抛 serviceLoading")
        } catch let error as CosyVoiceError {
            guard case .serviceLoading(let reason) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertTrue(reason.contains("loading model"))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testHealthConnectionRefusedMapsToServiceNotRunning() async {
        FakeCosyVoiceURLProtocol.setHandler { _ in
            .failure(URLError(.cannotConnectToHost))
        }
        let client = makeClient()
        do {
            _ = try await client.health()
            XCTFail("连接失败应抛 serviceNotRunning")
        } catch let error as CosyVoiceError {
            guard case .serviceNotRunning = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testHealthNonJSONMapsToInvalidResponse() async {
        FakeCosyVoiceURLProtocol.setHandler { _ in
            .http(status: 200, body: Data("<html>not cosyvoice</html>".utf8),
                  headers: ["Content-Type": "text/html"])
        }
        let client = makeClient()
        do {
            _ = try await client.health()
            XCTFail("非 JSON 200 应抛 invalidResponse（端口被其他服务占用）")
        } catch let error as CosyVoiceError {
            guard case .invalidResponse = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testSynthesizeRawReturns24kPCMAndRecordsRequest() async throws {
        let sampleRate = 24_000
        let frameCount = sampleRate / 4
        let samples = (0..<frameCount).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))) * 0.5
        }
        let wav = Self.makePCM16WAV(samples: samples, sampleRate: sampleRate)
        FakeCosyVoiceURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/tts")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = FakeCosyVoiceURLProtocol.bodyData(of: request)
            let object = try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
            XCTAssertEqual(object?["text"] as? String, "你好，测试一句话。")
            XCTAssertEqual(object?["voice_id"] as? String, "loli")
            XCTAssertEqual(object?["speed"] as? Double ?? 0, 1.5, accuracy: 0.0001)
            return .http(status: 200, body: wav, headers: ["Content-Type": "audio/wav"])
        }
        let outputDirectory = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: outputDirectory) }
        let client = makeClient(outputDirectory: outputDirectory)
        let result = try await client.synthesizeRaw(
            text: "你好，测试一句话。", voiceID: "loli", speed: 1.5)
        XCTAssertEqual(result.sampleRate, 24_000)
        XCTAssertEqual(result.samples.count, frameCount, accuracy: 4)
        XCTAssertEqual(result.duration, 0.25, accuracy: 0.02)
        XCTAssertTrue(result.samples.allSatisfy { $0.isFinite && abs($0) <= 1.0 })
        let rawURL = try XCTUnwrap(result.sourceWAVURL, "原始 WAV 应落盘用于诊断")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path))
        XCTAssertEqual(rawURL.deletingLastPathComponent().standardizedFileURL,
                       outputDirectory.standardizedFileURL)
    }

    func testSynthesizeRawServerErrorIncludesDetail() async {
        let errorJSON = """
        {"error":"unknown_voice","detail":"voice_id not found: xyz"}
        """.data(using: .utf8)!
        FakeCosyVoiceURLProtocol.setHandler { _ in
            .http(status: 400, body: errorJSON, headers: ["Content-Type": "application/json"])
        }
        let client = makeClient()
        do {
            _ = try await client.synthesizeRaw(text: "你好。", voiceID: "xyz", speed: 1)
            XCTFail("400 应抛错")
        } catch let error as CosyVoiceError {
            guard case .httpError(let status, let message) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(message.contains("unknown_voice"))
            XCTAssertTrue(message.contains("voice_id not found"))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testSynthesizeRawRejectsInvalidTextLocally() async {
        let client = makeClient()
        do {
            _ = try await client.synthesizeRaw(text: "   ", voiceID: "girl", speed: 1)
            XCTFail("空文本应在本地拒绝")
        } catch let error as CosyVoiceError {
            guard case .invalidRequest = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        do {
            _ = try await client.synthesizeRaw(
                text: String(repeating: "字", count: 501), voiceID: "girl", speed: 1)
            XCTFail("超长文本应在本地拒绝")
        } catch let error as CosyVoiceError {
            guard case .invalidRequest = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testSynthesizeRawInvalidWAVThrows() async {
        FakeCosyVoiceURLProtocol.setHandler { _ in
            .http(status: 200, body: Data("not a wav".utf8),
                  headers: ["Content-Type": "audio/wav"])
        }
        let client = makeClient()
        do {
            _ = try await client.synthesizeRaw(text: "你好。", voiceID: "girl", speed: 1)
            XCTFail("非 WAV 应抛 audioDecodeFailed")
        } catch let error as CosyVoiceError {
            guard case .audioDecodeFailed = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testVoicesParsesListAndErrorStatus() async throws {
        let body = """
        {"voices":[{"id":"girl","name":"少女"},{"id":"loli","name":"萝莉"}]}
        """.data(using: .utf8)!
        FakeCosyVoiceURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/voices")
            return .http(status: 200, body: body, headers: ["Content-Type": "application/json"])
        }
        let client = makeClient()
        let voices = try await client.voices()
        XCTAssertEqual(voices.map(\.id), ["girl", "loli"])

        FakeCosyVoiceURLProtocol.setHandler { _ in
            .http(status: 500, body: Data(#"{"error":"boom"}"#.utf8),
                  headers: ["Content-Type": "application/json"])
        }
        do {
            _ = try await client.voices()
            XCTFail("500 应抛错")
        } catch let error as CosyVoiceError {
            guard case .httpError(let status, _) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testRequestBuildersSetMethodPathAndTimeout() throws {
        let endpoint = URL(string: "http://127.0.0.1:5051")!
        let health = try CosyVoiceClient.healthRequest(endpoint: endpoint, timeout: 2)
        XCTAssertEqual(health.url?.absoluteString, "http://127.0.0.1:5051/health")
        XCTAssertEqual(health.httpMethod, "GET")
        XCTAssertEqual(health.timeoutInterval, 2, accuracy: 0.001)

        let tts = try CosyVoiceClient.ttsRequest(
            endpoint: endpoint, text: "hi", voiceID: "girl", speed: 1.25, timeout: 90)
        XCTAssertEqual(tts.url?.absoluteString, "http://127.0.0.1:5051/tts")
        XCTAssertEqual(tts.httpMethod, "POST")
        XCTAssertEqual(tts.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(tts.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "hi")
        XCTAssertEqual(object["voice_id"] as? String, "girl")
        XCTAssertEqual(object["speed"] as? Double ?? 0, 1.25, accuracy: 0.0001)
    }

    // MARK: - 4. WAV 解码

    func testWAVDecoderPCM16Mono() throws {
        let samples = (0..<480).map { index in
            Float(sin(2 * Double.pi * 220 * Double(index) / 24_000)) * 0.4
        }
        let data = Self.makePCM16WAV(samples: samples, sampleRate: 24_000)
        let decoded = try CosyVoiceWAVDecoder.decode(data)
        XCTAssertEqual(decoded.sampleRate, 24_000)
        XCTAssertEqual(decoded.channels, 1)
        XCTAssertEqual(decoded.bitsPerSample, 16)
        XCTAssertEqual(decoded.samples.count, 480)
        XCTAssertEqual(decoded.duration, 0.02, accuracy: 0.002)
    }

    func testWAVDecoderDownmixesStereo() throws {
        // 左右声道 +0.5 / -0.5 → 下混为 0。
        let frames = 100
        var data = Self.makePCM16WAV(
            samples: [Float](repeating: 0, count: frames * 2),
            sampleRate: 24_000, channels: 2)
        // 覆写 data 块内容：走到 WAV 头之后按 s16le 写入。
        let headerSize = 44
        for frame in 0..<frames {
            let left: Int16 = 16_384
            let right: Int16 = -16_384
            let base = headerSize + frame * 4
            data.replaceSubrange(base..<(base + 2), with: withUnsafeBytes(of: left.littleEndian) { Data($0) })
            data.replaceSubrange((base + 2)..<(base + 4),
                                 with: withUnsafeBytes(of: right.littleEndian) { Data($0) })
        }
        let decoded = try CosyVoiceWAVDecoder.decode(data)
        XCTAssertEqual(decoded.channels, 2)
        XCTAssertEqual(decoded.samples.count, frames)
        XCTAssertTrue(decoded.samples.allSatisfy { abs($0) < 0.001 })
    }

    func testWAVDecoderRejectsNonWAV() {
        XCTAssertThrowsError(try CosyVoiceWAVDecoder.decode(Data("RIFF".utf8))) { error in
            guard case CosyVoiceError.audioDecodeFailed = error else {
                return XCTFail("应抛 audioDecodeFailed：\(error)")
            }
        }
        XCTAssertThrowsError(try CosyVoiceWAVDecoder.decode(Data())) { error in
            guard case CosyVoiceError.audioDecodeFailed = error else {
                return XCTFail("应抛 audioDecodeFailed：\(error)")
            }
        }
    }

    // MARK: - 5. 安装器

    func testProgressParser() {
        XCTAssertEqual(
            CosyVoiceProgressParser.parse(line: "PROGRESS 0.42 下载模型"),
            .init(fraction: 0.42, message: "下载模型"))
        XCTAssertEqual(
            CosyVoiceProgressParser.parse(line: "PROGRESS 42% 解包"),
            .init(fraction: 0.42, message: "解包"))
        XCTAssertEqual(
            CosyVoiceProgressParser.parse(line: "  progress 1 完成  "),
            .init(fraction: 1.0, message: "完成"))
        XCTAssertEqual(
            CosyVoiceProgressParser.parse(line: "PROGRESS 1.8 越界")?.fraction,
            1.0, "进度必须收敛到 0...1")
        XCTAssertEqual(
            CosyVoiceProgressParser.parse(line: "PROGRESS -0.3 负数")?.fraction,
            0.0)
        XCTAssertNil(CosyVoiceProgressParser.parse(line: "PROGRESS abc 坏值"))
        XCTAssertNil(CosyVoiceProgressParser.parse(line: "PROGRESS"))
        XCTAssertNil(CosyVoiceProgressParser.parse(line: "正在下载模型"))
    }

    func testScriptResolutionAndScriptEnvironment() throws {
        try XCTSkipIf(CosyVoiceInstallation.repositoryRoot == nil, "不在源码仓库中运行")
        let runScript = try XCTUnwrap(
            CosyVoiceInstallation.runScript, "仓库内应能定位 scripts/run_cosyvoice.sh")
        let installScript = try XCTUnwrap(
            CosyVoiceInstallation.installScript, "仓库内应能定位 scripts/install_cosyvoice.sh")
        XCTAssertTrue(runScript.lastPathComponent.hasSuffix("run_cosyvoice.sh"))
        XCTAssertTrue(installScript.lastPathComponent.hasSuffix("install_cosyvoice.sh"))

        let home = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let environment = CosyVoiceInstallation.scriptEnvironment(
            home: home,
            endpoint: URL(string: "http://127.0.0.1:5151")!)
        XCTAssertEqual(environment["COSYVOICE_LOCAL_DIR"], home.path)
        XCTAssertEqual(environment["COSYVOICE_VENV"], home.appendingPathComponent("venv").path)
        XCTAssertEqual(environment["COSYVOICE_REFS"], home.appendingPathComponent("voices").path)
        XCTAssertEqual(environment["COSYVOICE_PORT"], "5151")
        XCTAssertEqual(environment["COSYVOICE_HOST"], "127.0.0.1")
        let serverDirectory = try XCTUnwrap(
            environment["COSYVOICE_SERVER_DIR"], "必须传 COSYVOICE_SERVER_DIR 给脚本")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: serverDirectory)
                    .appendingPathComponent("server.py").path),
            "COSYVOICE_SERVER_DIR 应指向 server.py 所在目录：\(serverDirectory)")
    }

    func testInstallationDetectionRequiresMarkerVenvAndModel() throws {
        let home = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        XCTAssertFalse(CosyVoiceInstallation.isInstalled(home: home))

        try createFakeInstall(home: home)
        XCTAssertTrue(CosyVoiceInstallation.isInstalled(home: home))
        XCTAssertEqual(
            CosyVoiceInstallation.modelDirectory(home: home).lastPathComponent,
            "Fun-CosyVoice3-0.5B-2512")

        // 标记文件缺失 → 未安装。
        try FileManager.default.removeItem(at: CosyVoiceInstallation.markerURL(home: home))
        XCTAssertFalse(CosyVoiceInstallation.isInstalled(home: home))

        // 标记回来但模型缺失 → 未安装。
        try Data("{}".utf8).write(to: CosyVoiceInstallation.markerURL(home: home))
        try FileManager.default.removeItem(
            at: CosyVoiceInstallation.modelDirectory(home: home)
                .appendingPathComponent("llm.pt"))
        XCTAssertFalse(CosyVoiceInstallation.isInstalled(home: home))
    }

    func testInstallSafetyGuard() {
        XCTAssertFalse(CosyVoiceInstallation.isSafeToDelete(URL(fileURLWithPath: "/")))
        XCTAssertFalse(CosyVoiceInstallation.isSafeToDelete(
            URL(fileURLWithPath: NSHomeDirectory())))
        XCTAssertFalse(CosyVoiceInstallation.isSafeToDelete(Self.makeTempDirectory()))
        XCTAssertTrue(CosyVoiceInstallation.isSafeToDelete(CosyVoiceInstallation.defaultHome))
    }

    func testInstallerRunsScriptAndParsesProgress() async throws {
        let home = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let script = try makeFakeInstallScript(
            body: """
            #!/bin/bash
            set -e
            echo "PROGRESS 0.10 检查运行环境"
            mkdir -p "$COSYVOICE_HOME/venv/bin" "$COSYVOICE_MODEL_DIR"
            printf '#!/bin/sh\\n' > "$COSYVOICE_HOME/venv/bin/python"
            chmod +x "$COSYVOICE_HOME/venv/bin/python"
            : > "$COSYVOICE_MODEL_DIR/llm.pt"
            : > "$COSYVOICE_MODEL_DIR/flow.pt"
            : > "$COSYVOICE_MODEL_DIR/hift.pt"
            : > "$COSYVOICE_MODEL_DIR/speech_tokenizer_v3.onnx"
            : > "$COSYVOICE_MODEL_DIR/campplus.onnx"
            : > "$COSYVOICE_MODEL_DIR/cosyvoice3.yaml"
            echo "PROGRESS 0.60 下载模型"
            echo "PROGRESS 1.00 安装完成"
            printf '{"version":1}\\n' > "$COSYVOICE_HOME/.installed"
            exit 0
            """)
        setenv(CosyVoiceInstallation.installScriptEnvironmentKey, script.path, 1)

        let installer = CosyVoiceInstaller(launcher: CosyVoiceProcessLauncher(), home: home)
        let initial = await installer.snapshot()
        XCTAssertEqual(initial.state, .notInstalled)
        XCTAssertEqual(initial.estimatedBytes, CosyVoiceInstaller.estimatedTotalBytes)

        try await installer.install(consent: true)
        let done = await installer.snapshot()
        guard case .installed = done.state else {
            return XCTFail("安装成功后状态应为 installed，实际：\(done.state)")
        }
        XCTAssertTrue(CosyVoiceInstallation.isInstalled(home: home))
        XCTAssertTrue(done.logTail.contains { $0.contains("0.60") || $0.contains("60%") },
                      "PROGRESS 行应进入日志摘要：\(done.logTail)")
    }

    func testInstallerRequiresConsent() async {
        let installer = CosyVoiceInstaller(home: Self.makeTempDirectory())
        do {
            try await installer.install(consent: false)
            XCTFail("未确认体积时必须拒绝")
        } catch let error as CosyVoiceInstallError {
            XCTAssertEqual(error, .consentRequired)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testInstallerCancelThrowsCancelled() async throws {
        let home = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let script = try makeFakeInstallScript(
            body: """
            #!/bin/bash
            echo "PROGRESS 0.10 开始"
            sleep 30
            exit 0
            """)
        setenv(CosyVoiceInstallation.installScriptEnvironmentKey, script.path, 1)
        let installer = CosyVoiceInstaller(launcher: CosyVoiceProcessLauncher(), home: home)
        let task = Task {
            try await installer.install(consent: true)
        }
        try await Task.sleep(for: .milliseconds(400))
        await installer.cancel()
        do {
            try await task.value
            XCTFail("取消安装应抛 cancelled")
        } catch let error as CosyVoiceInstallError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    // MARK: - 6. 健康轮询（注入 fake）

    func testHealthPollingRetriesLoadingThenReady() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int {
                lock.lock()
                defer { lock.unlock() }
                value += 1
                return value
            }
        }
        let counter = Counter()
        let clock = ManualClock()
        let readyHealth = CosyVoiceHealth(ok: true, ready: true, model: "m")
        let outcome = await CosyVoiceHealthPolling.waitUntilReady(
            timeout: 10,
            interval: 1,
            startedAt: clock.now,
            now: { clock.now },
            sleep: { clock.advance($0) },
            probe: {
                switch counter.next() {
                case 1, 2: return .loading("加载中")
                default: return .running(readyHealth)
                }
            },
            isProcessAlive: { true }
        )
        guard case .ready(let health) = outcome else {
            return XCTFail("应轮询到 ready，实际：\(outcome)")
        }
        XCTAssertEqual(health.model, "m")
    }

    func testHealthPollingTimesOut() async {
        let clock = ManualClock()
        let outcome = await CosyVoiceHealthPolling.waitUntilReady(
            timeout: 3,
            interval: 1,
            startedAt: clock.now,
            now: { clock.now },
            sleep: { clock.advance($0) },
            probe: { .loading("永远加载") },
            isProcessAlive: { true }
        )
        guard case .timedOut(let seconds) = outcome else {
            return XCTFail("应超时，实际：\(outcome)")
        }
        XCTAssertEqual(seconds, 3, accuracy: 0.001)
    }

    func testHealthPollingFailsWhenProcessExits() async {
        let outcome = await CosyVoiceHealthPolling.waitUntilReady(
            timeout: 30,
            interval: 1,
            probe: { .notRunning("连接失败") },
            isProcessAlive: { false }
        )
        guard case .failed(let reason) = outcome else {
            return XCTFail("进程退出应失败，实际：\(outcome)")
        }
        XCTAssertTrue(reason.contains("服务进程已退出"))
        XCTAssertTrue(reason.contains("连接失败"))
    }

    func testHealthPollingUnexpectedFailsImmediately() async {
        let outcome = await CosyVoiceHealthPolling.waitUntilReady(
            timeout: 30,
            interval: 1,
            probe: { .unexpected("端口 5051 被占用") },
            isProcessAlive: { true }
        )
        guard case .failed(let reason) = outcome else {
            return XCTFail("端口异常应立即失败，实际：\(outcome)")
        }
        XCTAssertEqual(reason, "端口 5051 被占用")
    }

    // MARK: - 6.4 音色库（CosyVoiceVoiceStore）

    func testVoiceStoreListPreservesOrderAndUnknownFields() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let voices = try await store.list()
        XCTAssertEqual(voices.map(\.id), ["girl", "loli", "onee"])
        XCTAssertTrue(voices.allSatisfy { $0.builtin && $0.personalUseOnly })

        // 编辑内置音色名称：不应破坏未知字段。
        _ = try await store.update(id: "girl", name: "少女·改")
        let manifest = try readJSONObject(fixture.appendingPathComponent("voices.json"))
        XCTAssertEqual(manifest["unknown_root"] as? String, "keep-me", "根未知字段必须保留")
        let girl = try XCTUnwrap(
            (manifest["voices"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == "girl" })
        XCTAssertEqual(girl["custom_field"] as? String, "keep-voice", "条目未知字段必须保留")
        XCTAssertEqual(girl["name"] as? String, "少女·改")
        XCTAssertEqual(girl["personal_use_only"] as? Bool, true)
        XCTAssertEqual(girl["builtin"] as? Bool, true)
    }

    func testVoiceStoreAddEditDeleteCustomVoice() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)

        let audio = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.4)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio) }

        let added = try await store.add(
            name: "测试音色 01",
            audioURL: audio,
            referenceText: "这是参考文本。",
            description: "管理器测试"
        )
        XCTAssertTrue(added.id.hasPrefix("custom-"))
        XCTAssertTrue(CosyVoiceVoiceStore.isValidID(added.id))
        XCTAssertFalse(added.builtin)
        XCTAssertTrue(added.personalUseOnly)
        XCTAssertEqual(added.referenceText, "这是参考文本。")
        XCTAssertEqual(added.mode, CosyVoiceManagedVoice.modeZeroShot)

        let directory = fixture.appendingPathComponent(added.id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("prompt.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("prompt.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("meta.json").path))

        // 24k mono 16-bit + 峰值归一（源幅度 0.4 → 目标约 0.95）。
        let wav = try Data(contentsOf: directory.appendingPathComponent("prompt.wav"))
        let decoded = try CosyVoiceWAVDecoder.decode(wav)
        XCTAssertEqual(decoded.sampleRate, 24_000)
        XCTAssertEqual(decoded.channels, 1)
        XCTAssertEqual(decoded.bitsPerSample, 16)
        XCTAssertEqual(decoded.duration, 6.0, accuracy: 0.1)
        let peak = decoded.samples.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, 0.95, accuracy: 0.02)

        // 列表：内置在前，自定义追加。
        let listed = try await store.list()
        XCTAssertEqual(listed.map(\.id).prefix(4), ["girl", "loli", "onee", added.id])

        // 编辑自定义：替换音频 + 改参考文本/名称。
        let audio2 = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 8, amplitude: 0.6)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio2) }
        let updated = try await store.update(
            id: added.id,
            name: "测试音色 02",
            description: "改过",
            referenceText: "新的参考文本。",
            audioURL: audio2
        )
        XCTAssertEqual(updated.name, "测试音色 02")
        XCTAssertEqual(updated.referenceText, "新的参考文本。")
        XCTAssertEqual(updated.duration ?? 0, 8.0, accuracy: 0.1)

        // 删除自定义：目录与 manifest 条目都应消失，内置保留。
        try await store.delete(id: added.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let afterDelete = try await store.list()
        XCTAssertFalse(afterDelete.contains { $0.id == added.id })
        XCTAssertEqual(afterDelete.map(\.id), ["girl", "loli", "onee"])
    }

    func testVoiceStoreConvertsStereoToMonoAndEmptyTextToCrossLingual() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let sampleRate = 16_000
        let frames = sampleRate * 6
        var interleaved: [Float] = []
        interleaved.reserveCapacity(frames * 2)
        for index in 0..<frames {
            let value = Float(sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate))) * 0.35
            interleaved.append(value)
            interleaved.append(-value)
        }
        let data = Self.makePCM16WAV(
            samples: interleaved, sampleRate: sampleRate, channels: 2)
        let stereo = FileManager.default.temporaryDirectory
            .appendingPathComponent("stereo-\(UUID().uuidString).wav")
        try data.write(to: stereo, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: stereo) }

        let added = try await store.add(
            name: "立体声测试", audioURL: stereo, referenceText: "",
            description: "")
        XCTAssertEqual(added.mode, CosyVoiceManagedVoice.modeCrossLingual,
                       "参考文本留空应自动 cross_lingual")
        XCTAssertFalse(added.hasReferenceText)
        let prompt = fixture.appendingPathComponent(added.id).appendingPathComponent("prompt.wav")
        let decoded = try CosyVoiceWAVDecoder.decode(try Data(contentsOf: prompt))
        XCTAssertEqual(decoded.channels, 1, "立体声必须下混为单声道")
        XCTAssertEqual(decoded.sampleRate, 24_000)
    }

    func testVoiceStoreBuiltinProtection() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let audio = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.5)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio) }

        do {
            try await store.delete(id: "girl")
            XCTFail("内置音色不允许删除")
        } catch let error as CosyVoiceVoiceStoreError {
            XCTAssertEqual(error, .builtinProtected)
        }
        do {
            _ = try await store.update(id: "girl", audioURL: audio)
            XCTFail("内置音色不允许替换音频")
        } catch let error as CosyVoiceVoiceStoreError {
            XCTAssertEqual(error, .builtinReferenceLocked)
        }
        do {
            _ = try await store.update(id: "girl", referenceText: "改参考文本")
            XCTFail("内置音色不允许改参考文本")
        } catch let error as CosyVoiceVoiceStoreError {
            XCTAssertEqual(error, .builtinReferenceLocked)
        }
        // 名称/简介允许。
        let renamed = try await store.update(id: "girl", name: "少女 2", description: "新简介")
        XCTAssertEqual(renamed.name, "少女 2")
        XCTAssertEqual(renamed.description, "新简介")
    }

    func testVoiceStoreValidatesDurationAndID() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let short = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 2, amplitude: 0.5)
        let long = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 31, amplitude: 0.5)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: short)
            try? FileManager.default.removeItem(at: long)
        }
        do {
            _ = try await store.add(
                name: "太短", audioURL: short, referenceText: "", description: "")
            XCTFail("2 秒音频应被拒绝")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .audioTooShort = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        }
        do {
            _ = try await store.add(
                name: "太长", audioURL: long, referenceText: "", description: "")
            XCTFail("31 秒音频应被拒绝")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .audioTooLong = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        }

        XCTAssertTrue(CosyVoiceVoiceStore.isValidID("custom-abc-123"))
        XCTAssertFalse(CosyVoiceVoiceStore.isValidID("../evil"))
        XCTAssertFalse(CosyVoiceVoiceStore.isValidID("girl/../../"))
        XCTAssertFalse(CosyVoiceVoiceStore.isValidID("-bad"))
        XCTAssertFalse(CosyVoiceVoiceStore.isValidID("A-Upper"))
        let generated = CosyVoiceVoiceStore.makeID(name: "测试 音色!")
        XCTAssertTrue(CosyVoiceVoiceStore.isValidID(generated))
        XCTAssertTrue(generated.hasPrefix("custom-voice-"))

        do {
            try await store.delete(id: "../evil")
            XCTFail("非法 id 应被拒绝")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .invalidID = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        }
    }

    func testVoiceStoreReloadFailureRollsBack() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let manifestBefore = try Data(contentsOf: fixture.appendingPathComponent("voices.json"))
        FakeCosyVoiceURLProtocol.setHandler { _ in
            .http(status: 500, body: Data(#"{"error":"reload_failed","detail":"boom"}"#.utf8),
                  headers: ["Content-Type": "application/json"])
        }
        let client = makeClient()
        let store = CosyVoiceVoiceStore(
            voicesDirectory: fixture, client: client, serviceReady: { true })
        let audio = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.5)
        let audio2 = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 7, amplitude: 0.4)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: audio2)
        }
        do {
            // 多条参考音频新增失败时，manifest 与整个音色目录（含 refs/）都要回滚。
            _ = try await store.add(
                name: "重载失败",
                references: [
                    .newAudio(audio, text: "A"),
                    .newAudio(audio2, text: "B"),
                ],
                description: "")
            XCTFail("服务 reload 失败应回滚并抛错")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .reloadFailed = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        }
        // manifest 内容与音色目录都应回滚。
        let manifestAfter = try Data(contentsOf: fixture.appendingPathComponent("voices.json"))
        XCTAssertEqual(manifestAfter, manifestBefore)
        let listed = try await store.list()
        XCTAssertEqual(listed.map(\.id), ["girl", "loli", "onee"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path)
            .contains { $0.hasPrefix("custom-") })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.appendingPathComponent("refs").path))
    }

    func testVoiceStoreManifestFallbackScansDirectories() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.removeItem(at: fixture.appendingPathComponent("voices.json"))
        let store = makeVoiceStore(voicesDirectory: fixture)
        let voices = try await store.list()
        XCTAssertEqual(voices.map(\.id), ["girl", "loli", "onee"])
        XCTAssertTrue(voices.allSatisfy { $0.hasPromptWAV })
    }

    func testVoiceStoreAddWhenManifestMissingPreservesScannedVoices() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.removeItem(at: fixture.appendingPathComponent("voices.json"))
        let store = makeVoiceStore(voicesDirectory: fixture)
        let audio = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.5)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio) }
        let added = try await store.add(
            name: "清单重建", audioURL: audio, referenceText: "",
            description: "")
        let manifest = try readJSONObject(fixture.appendingPathComponent("voices.json"))
        let ids = (manifest["voices"] as? [[String: Any]])?
            .compactMap { $0["id"] as? String } ?? []
        XCTAssertEqual(Set(ids), Set(["girl", "loli", "onee", added.id]),
                       "manifest 缺失时应从目录扫描重建，而不是丢掉内置音色")
        XCTAssertEqual(manifest["version"] as? Int, 2,
                       "重建后的清单带 references，版本应为 v2")
    }

    func testVoiceStoreAddAndUpdateWithoutConsentKeepsPersonalUse() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let audio = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.5)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio) }

        // 新交互：不需要「我确认仅限个人使用」勾选。
        let added = try await store.add(
            name: "无勾选音色", audioURL: audio, referenceText: "参考文本",
            description: "")
        XCTAssertTrue(added.personalUseOnly)
        let manifest = try readJSONObject(fixture.appendingPathComponent("voices.json"))
        let entry = try XCTUnwrap(
            (manifest["voices"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == added.id })
        XCTAssertEqual(entry["personal_use_only"] as? Bool, true,
                       "去掉勾选后 personal_use_only 仍必须恒 true")
        let meta = try readJSONObject(
            fixture.appendingPathComponent(added.id).appendingPathComponent("meta.json"))
        XCTAssertEqual(meta["personal_use_only"] as? Bool, true)

        let updated = try await store.update(id: added.id, name: "无勾选改名")
        XCTAssertEqual(updated.name, "无勾选改名")
        XCTAssertTrue(updated.personalUseOnly)
    }

    func testVoiceStoreEmptyDirectoryReturnsEmptyList() async throws {
        let empty = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: empty) }
        let store = makeVoiceStore(voicesDirectory: empty)
        let voices = try await store.list()
        XCTAssertTrue(voices.isEmpty, "App 不内置音色：空目录必须返回空列表")
        let hasVoices = try await store.hasVoices()
        XCTAssertFalse(hasVoices)
        XCTAssertFalse(CosyVoiceVoiceCatalog.canStartService(with: voices.map(\.asServiceVoice)))
        // 无音色时不能自动选 girl：默认设置、启动前置都应为空/false。
        let settings = VoiceSettings()
        XCTAssertEqual(settings.cosyVoiceVoiceID, "")
        XCTAssertEqual(settings.effectiveCosyVoiceVoiceID, "")
        XCTAssertFalse(settings.hasCosyVoiceVoice)
        XCTAssertFalse(CosyVoiceVoiceCatalog.canStartService(with: []))
    }

    func testClientRejectsEmptyVoiceIDWithoutNetwork() async {
        FakeCosyVoiceURLProtocol.setHandler { _ in
            XCTFail("未选择音色时不应发起 /tts 请求")
            return .failure(URLError(.unknown))
        }
        let client = makeClient()
        do {
            _ = try await client.synthesizeRaw(text: "你好。", voiceID: "", speed: 1)
            XCTFail("空音色应被本地拒绝")
        } catch let error as CosyVoiceError {
            guard case .invalidRequest = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    // MARK: - 6.6 音色导出（备份）

    func testVoiceStoreExportCustomVoiceZipAndNoMutation() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let audio = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.5)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio) }
        let added = try await store.add(
            name: "导出音色", audioURL: audio, referenceText: "这是导出用的参考文本。",
            description: "导出测试")

        let manifestBefore = try Data(contentsOf: fixture.appendingPathComponent("voices.json"))
        let promptBefore = try Data(
            contentsOf: fixture.appendingPathComponent(added.id).appendingPathComponent("prompt.wav"))
        let directoryBefore = try FileManager.default.contentsOfDirectory(
            atPath: fixture.appendingPathComponent(added.id).path).sorted()

        let destination = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        let result = try await store.exportVoice(id: added.id, to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.zipURL.path))
        XCTAssertEqual(result.voiceIDs, [added.id])
        XCTAssertEqual(result.zipURL.pathExtension.lowercased(), "zip")
        XCTAssertTrue(result.zipURL.lastPathComponent.hasSuffix(".cosyvoice-voice.zip"))

        let entries = try zipEntries(result.zipURL)
        for expected in [
            "\(added.id)/prompt.wav", "\(added.id)/prompt.txt",
            "\(added.id)/meta.json", "\(added.id)/voice.json",
            "\(added.id)/README.txt", "export.json",
        ] {
            XCTAssertTrue(entries.contains(expected),
                          "zip 缺少 \(expected)，实际：\(entries)")
        }
        let export = try JSONSerialization.jsonObject(
            with: try readZipEntry(result.zipURL, path: "export.json")) as? [String: Any]
        XCTAssertEqual(export?["personal_use_only"] as? Bool, true)
        // 不再写任何个人使用/禁止分发警告字段。
        XCTAssertNil(export?["notice_zh"])
        XCTAssertNil(export?["notice_en"])
        XCTAssertEqual(export?["schema"] as? String, CosyVoiceVoiceStore.exportSchema)
        XCTAssertEqual(export?["app"] as? String, "WeChatAI")
        XCTAssertTrue((export?["voices"] as? [String])?.contains(added.id) ?? false)
        let voiceJSON = try JSONSerialization.jsonObject(
            with: try readZipEntry(result.zipURL, path: "\(added.id)/voice.json")) as? [String: Any]
        XCTAssertEqual(voiceJSON?["personal_use_only"] as? Bool, true)
        XCTAssertEqual(voiceJSON?["builtin"] as? Bool, false)
        XCTAssertEqual(voiceJSON?["name"] as? String, "导出音色")
        let meta = try JSONSerialization.jsonObject(
            with: try readZipEntry(result.zipURL, path: "\(added.id)/meta.json")) as? [String: Any]
        XCTAssertEqual(meta?["personal_use_only"] as? Bool, true)
        let readme = String(
            data: try readZipEntry(result.zipURL, path: "\(added.id)/README.txt"),
            encoding: .utf8) ?? ""
        XCTAssertTrue(readme.contains("备份内容"), "README 应说明备份内容")
        XCTAssertTrue(readme.contains("恢复方式"), "README 应说明恢复方式")
        XCTAssertFalse(readme.contains("禁止分发"))
        XCTAssertFalse(readme.contains("请勿分发"))
        XCTAssertFalse(readme.lowercased().contains("personal use"))

        // 导出不改原 manifest/音色目录。
        XCTAssertEqual(try Data(contentsOf: fixture.appendingPathComponent("voices.json")),
                       manifestBefore)
        XCTAssertEqual(try Data(
            contentsOf: fixture.appendingPathComponent(added.id).appendingPathComponent("prompt.wav")),
            promptBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: fixture.appendingPathComponent(added.id).path).sorted(), directoryBefore)

        // 目的地没有 .zip 扩展名时自动补。
        let noExtension = destination.appendingPathComponent("backup-copy")
        let second = try await store.exportVoice(id: added.id, to: noExtension)
        XCTAssertEqual(second.zipURL.pathExtension.lowercased(), "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.zipURL.path))
    }

    func testVoiceStoreExportRejectsBuiltinAndEmptyCustom() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let destination = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }

        do {
            _ = try await store.exportVoice(id: "girl", to: destination)
            XCTFail("内置音色不可导出")
        } catch let error as CosyVoiceVoiceStoreError {
            XCTAssertEqual(error, .builtinExportDenied)
        }
        do {
            _ = try await store.exportVoice(id: "../evil", to: destination)
            XCTFail("非法 id 应被拒绝")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .invalidID = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        }
        do {
            _ = try await store.exportAllCustom(to: destination)
            XCTFail("只有内置音色时导出全部应报错")
        } catch let error as CosyVoiceVoiceStoreError {
            XCTAssertEqual(error, .nothingToExport)
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertTrue(remaining.isEmpty, "失败时不应留下 zip：\(remaining)")
    }

    func testVoiceStoreExportAllCustom() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let audio = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.4)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio) }
        let first = try await store.add(
            name: "备份 A", audioURL: audio, referenceText: "A 的参考文本",
            description: "")
        let second = try await store.add(
            name: "备份 B", audioURL: audio, referenceText: "B 的参考文本",
            description: "")

        let destination = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        let result = try await store.exportAllCustom(to: destination)
        XCTAssertEqual(Set(result.voiceIDs), Set([first.id, second.id]))
        XCTAssertTrue(result.zipURL.lastPathComponent.hasPrefix("cosyvoice-voices-"))
        XCTAssertEqual(result.zipURL.pathExtension.lowercased(), "zip")
        let entries = try zipEntries(result.zipURL)
        XCTAssertTrue(entries.contains("\(first.id)/prompt.wav"))
        XCTAssertTrue(entries.contains("\(second.id)/prompt.wav"))
        XCTAssertTrue(entries.contains("export.json"))
        XCTAssertFalse(entries.contains { $0.hasPrefix("girl/") || $0.hasPrefix("loli/") || $0.hasPrefix("onee/") },
                       "内置音色不应进入导出包")
        let export = try JSONSerialization.jsonObject(
            with: try readZipEntry(result.zipURL, path: "export.json")) as? [String: Any]
        let ids = Set(export?["voices"] as? [String] ?? [])
        XCTAssertEqual(ids, Set([first.id, second.id]))
    }

    func testVoiceStoreExportFileSafety() {
        XCTAssertFalse(CosyVoiceVoiceStore.safeFileName("a/b:c").contains("/"))
        XCTAssertFalse(CosyVoiceVoiceStore.safeFileName("a/b:c").contains(":"))
        XCTAssertEqual(CosyVoiceVoiceStore.safeFileName(".."), "voice")
        let zip = URL(fileURLWithPath: "/tmp/xxx/backup")
        XCTAssertEqual(
            CosyVoiceVoiceStore.exportDestination(
                zip, defaultFileName: "fallback.zip").lastPathComponent,
            "backup.zip")
        let alreadyZip = URL(fileURLWithPath: "/tmp/xxx/backup.ZIP")
        XCTAssertEqual(
            CosyVoiceVoiceStore.exportDestination(
                alreadyZip, defaultFileName: "fallback.zip").lastPathComponent,
            "backup.ZIP")
    }

    // MARK: - 6.7 多条参考音频（1–5 条）

    func testVoiceStoreAddMultipleReferenceClips() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let first = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.4)
        let second = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 7, amplitude: 0.5)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let added = try await store.add(
            name: "多条参考音色",
            references: [
                .newAudio(first, text: "  A  "),
                .newAudio(second, text: "B"),
            ],
            description: "两条参考音频"
        )
        XCTAssertEqual(added.referenceCount, 2)
        XCTAssertEqual(added.referenceText, "A\nB")
        XCTAssertEqual(added.mode, CosyVoiceManagedVoice.modeZeroShot)
        XCTAssertEqual(added.duration ?? 0, 13.25, accuracy: 0.05)

        let fileManager = FileManager.default
        let directory = fixture.appendingPathComponent(added.id)
        let refsDirectory = directory.appendingPathComponent("refs")
        for number in 1...2 {
            XCTAssertTrue(
                fileManager.fileExists(atPath: refsDirectory
                    .appendingPathComponent("ref-\(number).wav").path),
                "缺少 ref-\(number).wav")
            XCTAssertTrue(
                fileManager.fileExists(atPath: refsDirectory
                    .appendingPathComponent("ref-\(number).txt").path),
                "缺少 ref-\(number).txt")
        }
        XCTAssertEqual(
            try String(
                contentsOf: refsDirectory.appendingPathComponent("ref-1.txt"),
                encoding: .utf8),
            "A")
        XCTAssertEqual(
            try String(
                contentsOf: refsDirectory.appendingPathComponent("ref-2.txt"),
                encoding: .utf8),
            "B")
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("prompt.txt"),
                encoding: .utf8),
            "A\nB")

        // 合并 prompt = 6 + 7 + 0.25（片段间静音）。
        let prompt = try CosyVoiceWAVDecoder.decode(
            try Data(contentsOf: directory.appendingPathComponent("prompt.wav")))
        XCTAssertEqual(prompt.sampleRate, 24_000)
        XCTAssertEqual(prompt.channels, 1)
        XCTAssertEqual(prompt.duration, 13.25, accuracy: 0.15)
        let firstRef = try CosyVoiceWAVDecoder.decode(
            try Data(contentsOf: refsDirectory.appendingPathComponent("ref-1.wav")))
        XCTAssertEqual(firstRef.duration, 6.0, accuracy: 0.1)

        // voices.json：references 相对 voices 目录 + 保留兼容字段。
        let manifest = try readJSONObject(fixture.appendingPathComponent("voices.json"))
        XCTAssertEqual(manifest["version"] as? Int, 2, "写出 references 后清单版本应为 v2")
        let entry = try XCTUnwrap(
            (manifest["voices"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == added.id })
        let manifestReferences = try XCTUnwrap(entry["references"] as? [[String: Any]])
        XCTAssertEqual(manifestReferences.count, 2)
        XCTAssertEqual(
            manifestReferences.compactMap { $0["audio"] as? String },
            ["\(added.id)/refs/ref-1.wav", "\(added.id)/refs/ref-2.wav"])
        XCTAssertEqual(manifestReferences.compactMap { $0["text"] as? String }, ["A", "B"])
        XCTAssertEqual(entry["prompt_wav"] as? String, "\(added.id)/prompt.wav")
        XCTAssertEqual(entry["prompt_text"] as? String, "A\nB")
        XCTAssertEqual(entry["mode"] as? String, CosyVoiceManagedVoice.modeZeroShot)

        // meta.json：references 相对音色目录。
        let meta = try readJSONObject(directory.appendingPathComponent("meta.json"))
        let metaReferences = try XCTUnwrap(meta["references"] as? [[String: Any]])
        XCTAssertEqual(
            metaReferences.compactMap { $0["audio"] as? String },
            ["refs/ref-1.wav", "refs/ref-2.wav"])
        XCTAssertEqual(meta["reference_text"] as? String, "A\nB")
        XCTAssertEqual(meta["duration"] as? Double ?? 0, 13.25, accuracy: 0.05)

        // list() 读回。
        let listed = try await store.voice(id: added.id)
        let voice = try XCTUnwrap(listed)
        XCTAssertEqual(voice.referenceCount, 2)
        XCTAssertEqual(voice.referenceText, "A\nB")
        XCTAssertEqual(voice.mode, CosyVoiceManagedVoice.modeZeroShot)
        XCTAssertEqual(voice.duration ?? 0, 13.25, accuracy: 0.15)
        XCTAssertEqual(voice.references.map(\.text), ["A", "B"])
    }

    func testVoiceStoreMultipleReferencesCrossLingual() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let first = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.4)
        let second = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 7, amplitude: 0.5)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let added = try await store.add(
            name: "跨语种多条",
            references: [
                .newAudio(first, text: ""),
                .newAudio(second, text: "   "),
            ],
            description: "",
            crossLingual: true
        )
        XCTAssertEqual(added.mode, CosyVoiceManagedVoice.modeCrossLingual)
        XCTAssertEqual(added.referenceText, "")
        let directory = fixture.appendingPathComponent(added.id)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("prompt.txt"),
                encoding: .utf8),
            "")
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("refs/ref-1.txt"),
                encoding: .utf8),
            "")

        // cross-lingual 下文本不参与合成：部分填写也允许，模式仍为 cross_lingual。
        let mixed = try await store.add(
            name: "跨语种混合",
            references: [
                .newAudio(first, text: "A"),
                .newAudio(second, text: ""),
            ],
            description: "",
            crossLingual: true
        )
        XCTAssertEqual(mixed.mode, CosyVoiceManagedVoice.modeCrossLingual)
        XCTAssertEqual(mixed.referenceText, "A")
    }

    func testVoiceStoreMultipleReferenceValidation() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let audio = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.4)
        let longAudio = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 25, amplitude: 0.4)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: longAudio)
        }

        do {
            _ = try await store.add(name: "零条", references: [], description: "")
            XCTFail("0 条参考音频应被拒绝")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .missingReferences = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        }
        do {
            let tooMany = Array(
                repeating: CosyVoiceReferenceInput.newAudio(audio, text: "A"), count: 6)
            _ = try await store.add(name: "六条", references: tooMany, description: "")
            XCTFail("6 条参考音频应被拒绝")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .tooManyReferences(let max) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(max, 5)
        }
        do {
            _ = try await store.add(
                name: "部分文本",
                references: [
                    .newAudio(audio, text: "A"),
                    .newAudio(audio, text: "  "),
                ],
                description: ""
            )
            XCTFail("部分填写参考文本应被拒绝")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .inconsistentReferenceText = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        }
        do {
            let tooLong = Array(
                repeating: CosyVoiceReferenceInput.newAudio(longAudio, text: "A"), count: 3)
            _ = try await store.add(name: "总长过长", references: tooLong, description: "")
            XCTFail("合并总时长 75.5 秒应被拒绝")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .referenceTotalTooLong(let seconds) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(seconds, 75.5, accuracy: 0.2)
        }
        // CosyVoice3 speech tokenizer 硬限制 30s：6 + 25 + 0.25 = 31.25s 也必须拒绝。
        do {
            _ = try await store.add(
                name: "超过 30 秒",
                references: [
                    .newAudio(audio, text: "A"),
                    .newAudio(longAudio, text: "B"),
                ],
                description: ""
            )
            XCTFail("合并总时长 31.25 秒应被拒绝（CosyVoice3 参考音上限 30s）")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .referenceTotalTooLong(let seconds) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(seconds, 31.25, accuracy: 0.2)
        }

        let single = try await store.add(
            name: "合法单条", audioURL: audio, referenceText: "A", description: "")
        let outside = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.5)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        do {
            _ = try await store.update(
                id: single.id,
                references: [.existing(id: "evil", audioPath: "../evil.wav", text: "A")])
            XCTFail("逃逸音色目录的片段路径应被拒绝")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .invalidReference(let reason) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertTrue(reason.contains("音色目录"), "reason=\(reason)")
        }
        do {
            _ = try await store.update(
                id: single.id,
                references: [.existing(id: "outside", audioPath: outside.path, text: "A")])
            XCTFail("音色目录外的绝对路径应被拒绝")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .invalidReference = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        }

        // 失败的校验不应留下音色。
        let listed = try await store.list()
        XCTAssertEqual(listed.map(\.id).prefix(3), ["girl", "loli", "onee"])
        XCTAssertEqual(listed.count, 4, "只有「合法单条」被写入，其余校验失败不能落盘")
    }

    func testVoiceStoreUpdateReplacesReferenceClips() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let first = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.4)
        let second = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 7, amplitude: 0.5)
        let replacement = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 8, amplitude: 0.6)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
            try? FileManager.default.removeItem(at: replacement)
        }

        let added = try await store.add(
            name: "替换片段",
            references: [
                .newAudio(first, text: "A"),
                .newAudio(second, text: "B"),
            ],
            description: "")
        do {
            _ = try await store.update(id: added.id, referenceText: "X")
            XCTFail("多条参考音频时旧入口应拒绝")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .invalidReference(let reason) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertTrue(reason.contains("多条参考音频"), "reason=\(reason)")
        }

        let loaded = try await store.voice(id: added.id)
        let current = try XCTUnwrap(loaded)
        XCTAssertEqual(current.referenceCount, 2)
        let preservedPath = try XCTUnwrap(current.references.first?.audioPath)
        let updated = try await store.update(
            id: added.id,
            name: "替换片段 2",
            references: [
                .existing(id: current.references[0].id, audioPath: preservedPath, text: "A"),
                .newAudio(replacement, text: "C"),
            ],
            crossLingual: false
        )
        XCTAssertEqual(updated.name, "替换片段 2")
        XCTAssertEqual(updated.referenceCount, 2)
        XCTAssertEqual(updated.referenceText, "A\nC")
        XCTAssertEqual(updated.duration ?? 0, 14.25, accuracy: 0.05)

        let directory = fixture.appendingPathComponent(added.id)
        let refsDirectory = directory.appendingPathComponent("refs")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: refsDirectory.path).sorted(),
            ["ref-1.txt", "ref-1.wav", "ref-2.txt", "ref-2.wav"])
        XCTAssertEqual(
            try String(
                contentsOf: refsDirectory.appendingPathComponent("ref-2.txt"),
                encoding: .utf8),
            "C")
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("prompt.txt"),
                encoding: .utf8),
            "A\nC")
        let prompt = try CosyVoiceWAVDecoder.decode(
            try Data(contentsOf: directory.appendingPathComponent("prompt.wav")))
        XCTAssertEqual(prompt.duration, 14.25, accuracy: 0.15)

        // 2 条 → 1 条：ref-2 被清理，prompt.txt 只剩该条文本。
        let reloaded = try await store.voice(id: added.id)
        let latest = try XCTUnwrap(reloaded)
        let keptPath = try XCTUnwrap(latest.references.first?.audioPath)
        let single = try await store.update(
            id: added.id,
            references: [.existing(
                id: latest.references[0].id, audioPath: keptPath, text: "A")],
            crossLingual: nil
        )
        XCTAssertEqual(single.referenceCount, 1)
        XCTAssertEqual(single.referenceText, "A")
        XCTAssertEqual(single.mode, CosyVoiceManagedVoice.modeZeroShot,
                       "文本非空时按文本推断为 zero_shot")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: refsDirectory.path).sorted(),
            ["ref-1.txt", "ref-1.wav"])
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("prompt.txt"),
                encoding: .utf8),
            "A")
        let singlePrompt = try CosyVoiceWAVDecoder.decode(
            try Data(contentsOf: directory.appendingPathComponent("prompt.wav")))
        XCTAssertEqual(singlePrompt.duration, 6.0, accuracy: 0.15)

        let manifest = try readJSONObject(fixture.appendingPathComponent("voices.json"))
        let entry = try XCTUnwrap(
            (manifest["voices"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == added.id })
        XCTAssertEqual((entry["references"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(entry["prompt_text"] as? String, "A")
    }

    func testVoiceStoreLoadsLegacyVoiceAsSingleReferenceAndRenameKeepsAudio() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let girlDirectory = fixture.appendingPathComponent("girl")
        let promptBefore = try Data(
            contentsOf: girlDirectory.appendingPathComponent("prompt.wav"))

        let loaded = try await store.voice(id: "girl")
        let voice = try XCTUnwrap(loaded)
        XCTAssertEqual(voice.referenceCount, 1)
        XCTAssertEqual(voice.referenceText, "内置参考文本 girl。")
        let audioPath = try XCTUnwrap(voice.references.first?.audioPath)
        XCTAssertEqual(
            URL(fileURLWithPath: audioPath).standardizedFileURL,
            girlDirectory.appendingPathComponent("prompt.wav").standardizedFileURL,
            "旧音色的唯一片段应指向 prompt.wav")

        // 只改名：不重写音频、不迁移 refs/。
        let renamed = try await store.update(id: "girl", name: "少女·改名")
        XCTAssertEqual(renamed.referenceCount, 1)
        XCTAssertEqual(renamed.referenceText, "内置参考文本 girl。")
        XCTAssertEqual(
            try Data(contentsOf: girlDirectory.appendingPathComponent("prompt.wav")),
            promptBefore,
            "只改名不应重写参考音频")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: girlDirectory.appendingPathComponent("refs").path),
            "只改名不应迁移到 refs/ 布局")
        let manifest = try readJSONObject(fixture.appendingPathComponent("voices.json"))
        XCTAssertEqual(manifest["version"] as? Int, 1, "旧清单未迁移时应保持原版本")
    }

    func testVoiceStoreParsesReferenceEntriesAndSkipsInvalidClips() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let first = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.4)
        let second = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 7, amplitude: 0.5)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let added = try await store.add(
            name: "清单解析",
            references: [
                .newAudio(first, text: "A"),
                .newAudio(second, text: "B"),
            ],
            description: "")

        func rewriteReferences(_ transform: (inout [[String: Any]]) -> Void) throws {
            let url = fixture.appendingPathComponent("voices.json")
            var manifest = try readJSONObject(url)
            var entries = try XCTUnwrap(manifest["voices"] as? [[String: Any]])
            let index = try XCTUnwrap(
                entries.firstIndex { ($0["id"] as? String) == added.id })
            var references = try XCTUnwrap(
                entries[index]["references"] as? [[String: Any]])
            transform(&references)
            entries[index]["references"] = references
            manifest["voices"] = entries
            let data = try JSONSerialization.data(
                withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        }

        try rewriteReferences { $0[1]["audio"] = "../escape.wav" }
        let parsedOne = try await store.voice(id: added.id)
        let one = try XCTUnwrap(parsedOne)
        XCTAssertEqual(one.referenceCount, 1, "逃逸路径的片段应被跳过")
        XCTAssertEqual(one.referenceText, "A")

        try rewriteReferences {
            $0[0]["audio"] = "../escape.wav"
            $0[1]["audio"] = "\(added.id)/refs/missing-ref.wav"
        }
        let parsedFallback = try await store.voice(id: added.id)
        let fallback = try XCTUnwrap(parsedFallback)
        XCTAssertEqual(fallback.referenceCount, 1, "全部片段失效时回退旧 prompt")
        XCTAssertEqual(fallback.referenceText, "A\nB", "回退时使用条目 prompt_text")
        let fallbackPath = try XCTUnwrap(fallback.references.first?.audioPath)
        XCTAssertEqual(URL(fileURLWithPath: fallbackPath).lastPathComponent, "prompt.wav")
    }

    func testVoiceStoreScanDirectoriesReadsRefsLayout() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.removeItem(at: fixture.appendingPathComponent("voices.json"))
        let store = makeVoiceStore(voicesDirectory: fixture)

        let id = "custom-scan-refs"
        let directory = fixture.appendingPathComponent(id)
        let refsDirectory = directory.appendingPathComponent("refs")
        try FileManager.default.createDirectory(
            at: refsDirectory, withIntermediateDirectories: true)
        _ = try makeAudioFile(
            in: refsDirectory, seconds: 6, amplitude: 0.4, fileName: "ref-1.wav")
        try Data("片段一".utf8)
            .write(to: refsDirectory.appendingPathComponent("ref-1.txt"))
        _ = try makeAudioFile(
            in: refsDirectory, seconds: 7, amplitude: 0.5, fileName: "ref-2.wav")
        let meta: [String: Any] = [
            "id": id,
            "name": "扫描音色",
            "description": "",
            "mode": "zero_shot",
            "duration": 13.25,
            "source": "app-import",
            "references": [
                ["audio": "refs/ref-1.wav", "text": "片段一"],
                ["audio": "refs/ref-2.wav", "text": "片段二"],
            ],
        ]
        let metaData = try JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try metaData.write(to: directory.appendingPathComponent("meta.json"))

        // 无 prompt.wav 也能展示（hasPromptWAV=false）；ref-2 文本从 meta 兜底。
        let voices = try await store.list()
        let parsed = try XCTUnwrap(voices.first { $0.id == id })
        XCTAssertEqual(parsed.referenceCount, 2)
        XCTAssertEqual(parsed.referenceText, "片段一\n片段二")
        XCTAssertEqual(parsed.mode, CosyVoiceManagedVoice.modeZeroShot)
        XCTAssertEqual(parsed.duration ?? 0, 13.25, accuracy: 0.05)
        XCTAssertFalse(parsed.hasPromptWAV, "prompt.wav 缺失时仍可展示但不应报告可用")

        // 补上 prompt.wav 后 hasPromptWAV 恢复。
        _ = try makeAudioFile(
            in: directory, seconds: 6, amplitude: 0.4, fileName: "prompt.wav")
        let refreshedVoice = try await store.voice(id: id)
        let refreshed = try XCTUnwrap(refreshedVoice)
        XCTAssertTrue(refreshed.hasPromptWAV)
    }

    func testVoiceStoreExportsMultipleReferences() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let first = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.4)
        let second = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 7, amplitude: 0.5)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let added = try await store.add(
            name: "导出多条参考音",
            references: [
                .newAudio(first, text: "A"),
                .newAudio(second, text: "B"),
            ],
            description: "两条参考音频")
        let directory = fixture.appendingPathComponent(added.id)
        let manifestBefore = try Data(contentsOf: fixture.appendingPathComponent("voices.json"))
        let directoryBefore = try FileManager.default.contentsOfDirectory(
            atPath: directory.path).sorted()

        let destination = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        let result = try await store.exportVoice(id: added.id, to: destination)
        let entries = try zipEntries(result.zipURL)
        for expected in [
            "\(added.id)/prompt.wav", "\(added.id)/prompt.txt",
            "\(added.id)/refs/ref-1.wav", "\(added.id)/refs/ref-1.txt",
            "\(added.id)/refs/ref-2.wav", "\(added.id)/refs/ref-2.txt",
            "\(added.id)/meta.json", "\(added.id)/voice.json",
            "\(added.id)/README.txt", "export.json",
        ] {
            XCTAssertTrue(entries.contains(expected), "zip 缺少 \(expected)，实际：\(entries)")
        }
        let voiceJSON = try JSONSerialization.jsonObject(
            with: try readZipEntry(result.zipURL, path: "\(added.id)/voice.json"))
            as? [String: Any]
        XCTAssertEqual(voiceJSON?["reference_count"] as? Int, 2)
        let meta = try JSONSerialization.jsonObject(
            with: try readZipEntry(result.zipURL, path: "\(added.id)/meta.json"))
            as? [String: Any]
        let references = try XCTUnwrap(meta?["references"] as? [[String: Any]])
        XCTAssertEqual(references.count, 2)
        XCTAssertEqual(
            references.compactMap { $0["audio"] as? String },
            ["refs/ref-1.wav", "refs/ref-2.wav"])
        XCTAssertEqual(meta?["reference_text"] as? String, "A\nB")
        XCTAssertEqual(meta?["prompt_text"] as? String, "A\nB")
        let readme = String(
            data: try readZipEntry(result.zipURL, path: "\(added.id)/README.txt"),
            encoding: .utf8) ?? ""
        XCTAssertTrue(readme.contains("refs/"), "README 应说明 refs/ 内容")
        XCTAssertTrue(readme.contains("多条参考音频"), "README 应说明多条参考音频")

        // 导出不修改原目录/manifest。
        XCTAssertEqual(
            try Data(contentsOf: fixture.appendingPathComponent("voices.json")),
            manifestBefore)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            directoryBefore)
    }

    func testVoiceStoreExportLegacyVoiceKeepsOriginalLayout() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let legacyID = "custom-legacy-layout"
        try makeLegacyCustomVoice(
            in: fixture, id: legacyID, name: "旧布局音色", text: "旧参考文本")

        let destination = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        let result = try await store.exportVoice(id: legacyID, to: destination)
        let entries = try zipEntries(result.zipURL)
        XCTAssertTrue(entries.contains("\(legacyID)/prompt.wav"))
        XCTAssertTrue(entries.contains("\(legacyID)/prompt.txt"))
        XCTAssertTrue(entries.contains("\(legacyID)/meta.json"))
        XCTAssertFalse(entries.contains { $0.contains("/refs/") },
                       "旧音色导出不应包含 refs/：\(entries)")
        let voiceJSON = try JSONSerialization.jsonObject(
            with: try readZipEntry(result.zipURL, path: "\(legacyID)/voice.json"))
            as? [String: Any]
        XCTAssertEqual(voiceJSON?["reference_count"] as? Int, 1)
        let meta = try JSONSerialization.jsonObject(
            with: try readZipEntry(result.zipURL, path: "\(legacyID)/meta.json"))
            as? [String: Any]
        XCTAssertNil(meta?["references"])
        XCTAssertEqual(meta?["reference_text"] as? String, "旧参考文本")
    }

    func testVoiceStoreUpdateReloadFailureRollsBack() async throws {
        let fixture = try makeVoicesFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let store = makeVoiceStore(voicesDirectory: fixture)
        let audio = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 6, amplitude: 0.4)
        let replacement = try makeAudioFile(
            in: FileManager.default.temporaryDirectory, seconds: 7, amplitude: 0.5)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: replacement)
        }
        let added = try await store.add(
            name: "更新回滚", references: [.newAudio(audio, text: "A")], description: "")
        let directory = fixture.appendingPathComponent(added.id)
        let refsDirectory = directory.appendingPathComponent("refs")
        let manifestBefore = try Data(contentsOf: fixture.appendingPathComponent("voices.json"))
        let promptBefore = try Data(contentsOf: directory.appendingPathComponent("prompt.wav"))
        let promptTextBefore = try Data(
            contentsOf: directory.appendingPathComponent("prompt.txt"))
        let refsBefore = try FileManager.default.contentsOfDirectory(
            atPath: refsDirectory.path).sorted()

        FakeCosyVoiceURLProtocol.setHandler { _ in
            .http(status: 500, body: Data(#"{"error":"reload_failed","detail":"boom"}"#.utf8),
                  headers: ["Content-Type": "application/json"])
        }
        let failingStore = CosyVoiceVoiceStore(
            voicesDirectory: fixture, client: makeClient(), serviceReady: { true })
        do {
            _ = try await failingStore.update(
                id: added.id,
                references: [.newAudio(replacement, text: "B")],
                crossLingual: false)
            XCTFail("服务 reload 失败应回滚并抛错")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .reloadFailed = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.appendingPathComponent("voices.json")),
            manifestBefore, "manifest 必须逐字节回滚")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("prompt.wav")),
            promptBefore, "合并 prompt 必须回滚")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("prompt.txt")),
            promptTextBefore)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: refsDirectory.path).sorted(),
            refsBefore, "refs/ 必须回滚")
        let listed = try await store.voice(id: added.id)
        let voice = try XCTUnwrap(listed)
        XCTAssertEqual(voice.referenceCount, 1)
        XCTAssertEqual(voice.referenceText, "A")
    }

    func testVoiceOldResponseDefaultsPersonalAndBuiltin() throws {
        let json = Data("""
        {"voices":[
          {"id":"girl","name":"少女","prompt_text":"hi","mode":"zero_shot"},
          {"id":"custom-x","name":"自定义"},
          {"id":"onee","name":"御姐","personal_use_only":false,"builtin":true}
        ]}
        """.utf8)
        let list = try JSONDecoder().decode(CosyVoiceVoiceList.self, from: json)
        XCTAssertEqual(list.voices.count, 3)
        XCTAssertTrue(list.voices[0].personalUseOnly)
        XCTAssertTrue(list.voices[0].builtin, "旧响应缺 builtin 时按内置 id 推断")
        XCTAssertFalse(list.voices[1].builtin)
        XCTAssertTrue(list.voices[1].personalUseOnly)
        XCTAssertTrue(list.voices[2].builtin)

        let merged = CosyVoiceVoiceCatalog.merged(remote: list.voices)
        XCTAssertTrue(merged.allSatisfy { $0.personalUseOnly })
        // remote 没有 loli，不能凭空补出来。
        XCTAssertEqual(merged.map(\.id), ["girl", "onee", "custom-x"])
        XCTAssertTrue(merged.allSatisfy { !$0.name.isEmpty })
    }

    func testClientReloadVoices() async throws {
        let body = Data("""
        {"ok":true,"voices":[
          {"id":"girl","name":"少女","personal_use_only":true,"builtin":true},
          {"id":"custom-a","name":"自定义 A","personal_use_only":true,"builtin":false}
        ]}
        """.utf8)
        FakeCosyVoiceURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/voices/reload")
            return .http(status: 200, body: body, headers: ["Content-Type": "application/json"])
        }
        let client = makeClient()
        let voices = try await client.reloadVoices()
        XCTAssertEqual(voices.map(\.id), ["girl", "custom-a"])
        XCTAssertTrue(voices[1].personalUseOnly)

        FakeCosyVoiceURLProtocol.setHandler { _ in
            .http(status: 500, body: Data(#"{"error":"reload_failed"}"#.utf8),
                  headers: ["Content-Type": "application/json"])
        }
        do {
            _ = try await client.reloadVoices()
            XCTFail("500 应抛错")
        } catch let error as CosyVoiceError {
            guard case .httpError(let status, _) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(status, 500)
        }
    }

    /// UI/本地化文案里不再出现个人使用/禁止分发提醒（内部 personal_use_only 字段不受影响）。
    func testUIRemovesPersonalUseReminderText() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WeChatAITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
        let files = [
            appRoot.appendingPathComponent("Sources/WeChatBot/Views/VoiceSettingsPanel.swift"),
            appRoot.appendingPathComponent(
                "Sources/WeChatBot/Views/Components/CosyVoiceVoiceManagerSheet.swift"),
            appRoot.appendingPathComponent("Packaging/zh-Hans.lproj/Localizable.strings"),
            appRoot.appendingPathComponent("Packaging/en.lproj/Localizable.strings"),
        ]
        let forbidden = [
            "仅限个人使用", "请勿分发", "禁止分发", "仅供本人备份", "请使用本人",
            "personal use only", "do not distribute", "personal backup only",
        ]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for phrase in forbidden {
                XCTAssertFalse(
                    text.localizedCaseInsensitiveContains(phrase),
                    "\(file.lastPathComponent) 仍包含提醒文案：\(phrase)")
            }
        }
    }

    // MARK: - 6.5 真实服务端到端（默认跳过；`WECHATAI_COSYVOICE_E2E=1` 手动跑）

    /// 拉起真实 `scripts/run_cosyvoice.sh`（复用已运行服务）并合成一句话。
    /// 需要真实的 `_local/cosyvoice`（venv + 模型 + 音色 + `.installed`），故默认跳过。
    func testRealServiceEndToEndWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WECHATAI_COSYVOICE_E2E"] == "1",
            "设置 WECHATAI_COSYVOICE_E2E=1 才跑真实 CosyVoice 服务测试")
        let environment = ProcessInfo.processInfo.environment
        let home: URL
        if let rawHome = environment["WECHATAI_COSYVOICE_E2E_HOME"],
           !rawHome.isEmpty {
            home = URL(fileURLWithPath: (rawHome as NSString).expandingTildeInPath)
        } else {
            home = CosyVoiceInstallation.home
        }
        try XCTSkipUnless(
            CosyVoiceInstallation.isInstalled(home: home),
            "CosyVoice3 尚未完整安装（缺 .installed/venv/模型）：\(home.path)")
        let endpoint = URL(
            string: environment["WECHATAI_COSYVOICE_E2E_ENDPOINT"] ?? "http://127.0.0.1:5051")!
        let outputDirectory = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: outputDirectory) }
        let client = CosyVoiceClient(
            configuration: CosyVoiceClient.Configuration(
                endpoint: endpoint,
                healthTimeout: 5,
                voicesTimeout: 5,
                synthesisTimeout: 180,
                outputDirectory: outputDirectory),
            session: nil,
            transport: nil
        )
        let runtime = CosyVoiceRuntime(
            client: client,
            launcher: CosyVoiceProcessLauncher(),
            home: home)
        do {
            let health = try await runtime.start(endpoint: endpoint)
            XCTAssertTrue(health.isReady)
            let raw = try await client.synthesizeRaw(
                text: "你好呀，我是你的微信 AI 助手。",
                voiceID: "girl",
                speed: 1.0,
                timeout: 180)
            XCTAssertEqual(raw.sampleRate, 24_000)
            XCTAssertGreaterThan(raw.duration, 0.3)
            XCTAssertNotNil(raw.sourceWAVURL)
            if let url = raw.sourceWAVURL {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
            print(String(
                format: "[CosyVoice E2E] duration=%.2fs samples=%d",
                raw.duration, raw.samples.count))
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    /// 真实服务 + 真实 voices 目录副本：新增 → reload → /voices 出现 → 改名 → 删除。
    /// 需要完整安装；默认跳过（`WECHATAI_COSYVOICE_E2E=1` 手动跑）。
    func testRealVoiceStoreAddReloadDeleteWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WECHATAI_COSYVOICE_E2E"] == "1",
            "设置 WECHATAI_COSYVOICE_E2E=1 才跑真实 CosyVoice 服务测试")
        let realHome = CosyVoiceInstallation.home
        try XCTSkipUnless(
            CosyVoiceInstallation.isInstalled(home: realHome),
            "CosyVoice3 尚未完整安装：\(realHome.path)")

        // 临时 home：venv/models/repo 用 symlink 复用真实安装，voices 用副本（不碰个人参考音）。
        let home = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let fileManager = FileManager.default
        for name in ["venv", "models", "repo"] {
            try fileManager.createSymbolicLink(
                at: home.appendingPathComponent(name),
                withDestinationURL: realHome.appendingPathComponent(name))
        }
        try fileManager.copyItem(
            at: realHome.appendingPathComponent("voices"),
            to: home.appendingPathComponent("voices"))
        try Data(#"{"version":1}"#.utf8)
            .write(to: home.appendingPathComponent(".installed"))

        let endpoint = URL(string: "http://127.0.0.1:5061")!
        let outputDirectory = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: outputDirectory) }
        let client = CosyVoiceClient(
            configuration: CosyVoiceClient.Configuration(
                endpoint: endpoint,
                healthTimeout: 5,
                voicesTimeout: 20,
                synthesisTimeout: 180,
                outputDirectory: outputDirectory))
        let runtime = CosyVoiceRuntime(
            client: client, launcher: CosyVoiceProcessLauncher(), home: home)
        do {
            let health = try await runtime.start(endpoint: endpoint, timeout: 150)
            XCTAssertTrue(health.isReady)

            let store = CosyVoiceVoiceStore(
                voicesDirectory: home.appendingPathComponent("voices"),
                client: client,
                serviceReady: { runtime.isServiceReadySnapshot }
            )
            // 用本机已有音色当新增素材（保证是可解码的参考音频）。
            let sourceAudio = home.appendingPathComponent("voices/girl/prompt.wav")
            try XCTSkipUnless(
                fileManager.fileExists(atPath: sourceAudio.path), "缺少本机参考音")
            let audio = Self.makeTempDirectory().appendingPathComponent("e2e-voice.wav")
            addTeardownBlock { try? FileManager.default.removeItem(at: audio) }
            try fileManager.copyItem(at: sourceAudio, to: audio)
            let reference = try String(
                contentsOf: home.appendingPathComponent("voices/girl/prompt.txt"),
                encoding: .utf8)

            let added = try await store.add(
                name: "E2E 临时音色",
                audioURL: audio,
                referenceText: reference,
                description: "仅测试用，随后删除"
            )
            XCTAssertTrue(added.id.hasPrefix("custom-"))
            var serviceVoices = try await client.voices(endpoint: endpoint)
            XCTAssertTrue(
                serviceVoices.contains { $0.id == added.id },
                "新增后服务 reload 应能看到音色，实际：\(serviceVoices.map(\.id))")

            _ = try await store.update(id: added.id, name: "E2E 临时音色改名")
            serviceVoices = try await client.voices(endpoint: endpoint)
            let renamed = try XCTUnwrap(
                serviceVoices.first { $0.id == added.id }, "改名后音色应仍在服务列表")
            XCTAssertEqual(renamed.name, "E2E 临时音色改名")

            try await store.delete(id: added.id)
            serviceVoices = try await client.voices(endpoint: endpoint)
            XCTAssertFalse(serviceVoices.contains { $0.id == added.id })
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
        let afterStop = await runtime.snapshot()
        XCTAssertEqual(afterStop.state, .stopped)
    }

    // MARK: - 7. Runtime（fake 进程 / fake 服务）

    func testRuntimeReusesAlreadyRunningService() async throws {
        let home = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try createFakeInstall(home: home)
        let readyJSON = Self.readyHealthJSON()
        FakeCosyVoiceURLProtocol.setHandler { _ in
            .http(status: 200, body: readyJSON, headers: ["Content-Type": "application/json"])
        }
        let client = makeClient()
        let launcher = FakeCosyVoiceLauncher()
        let runtime = CosyVoiceRuntime(client: client, launcher: launcher, home: home)
        let health = try await runtime.start(endpoint: URL(string: "http://127.0.0.1:5051")!)
        XCTAssertTrue(health.isReady)
        XCTAssertEqual(launcher.launchCount, 0, "已有服务时不应重复启动进程")
        let snapshot = await runtime.snapshot()
        XCTAssertTrue(snapshot.state.isRunning)
        XCTAssertFalse(snapshot.ownsProcess)
        XCTAssertTrue(runtime.isServiceReadySnapshot)

        await runtime.stop()
        let stopped = await runtime.snapshot()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(runtime.isServiceReadySnapshot)
    }

    func testRuntimeRejectsPortConflictWithoutLaunching() async throws {
        let home = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try createFakeInstall(home: home)
        FakeCosyVoiceURLProtocol.setHandler { _ in
            .http(status: 200, body: Data("<html>another service</html>".utf8),
                  headers: ["Content-Type": "text/html"])
        }
        let client = makeClient()
        let launcher = FakeCosyVoiceLauncher()
        let runtime = CosyVoiceRuntime(client: client, launcher: launcher, home: home)
        do {
            _ = try await runtime.start(endpoint: URL(string: "http://127.0.0.1:5051")!)
            XCTFail("端口被其他服务占用时应失败")
        } catch {
            // 预期：serviceUnavailable（端口冲突），且不启动新进程。
        }
        XCTAssertEqual(launcher.launchCount, 0)
        let snapshot = await runtime.snapshot()
        guard case .failed = snapshot.state else {
            return XCTFail("状态应为 failed，实际：\(snapshot.state)")
        }
    }

    func testRuntimeNotInstalledThrowsWithoutLaunching() async throws {
        let home = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let client = makeClient()
        let launcher = FakeCosyVoiceLauncher()
        let runtime = CosyVoiceRuntime(client: client, launcher: launcher, home: home)
        do {
            _ = try await runtime.start(endpoint: URL(string: "http://127.0.0.1:5051")!)
            XCTFail("未安装时应抛 notInstalled")
        } catch let error as CosyVoiceError {
            XCTAssertEqual(error, .notInstalled)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testRuntimeFailsWhenSpawnedProcessExits() async throws {
        let home = Self.makeTempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try createFakeInstall(home: home)
        FakeCosyVoiceURLProtocol.setHandler { _ in
            .failure(URLError(.cannotConnectToHost))
        }
        let client = makeClient()
        let process = FakeCosyVoiceProcess(pid: 9_001, running: false)
        let launcher = FakeCosyVoiceLauncher { process }
        let runtime = CosyVoiceRuntime(client: client, launcher: launcher, home: home)
        do {
            _ = try await runtime.start(
                endpoint: URL(string: "http://127.0.0.1:5051")!, timeout: 3)
            XCTFail("服务进程退出后启动应失败")
        } catch {
            // 预期：serviceUnavailable（进程已退出/启动超时）。
        }
        XCTAssertEqual(launcher.launchCount, 1)
        let snapshot = await runtime.snapshot()
        guard case .failed = snapshot.state else {
            return XCTFail("状态应为 failed，实际：\(snapshot.state)")
        }
    }

    // MARK: - Helpers

    private func makeClient(
        outputDirectory: URL? = nil
    ) -> CosyVoiceClient {
        let configuration = CosyVoiceClient.Configuration(
            endpoint: URL(string: "http://127.0.0.1:5051")!,
            healthTimeout: 1,
            voicesTimeout: 1,
            synthesisTimeout: 2,
            outputDirectory: outputDirectory ?? Self.makeTempDirectory()
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FakeCosyVoiceURLProtocol.self]
        sessionConfiguration.timeoutIntervalForRequest = 2
        sessionConfiguration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: sessionConfiguration)
        return CosyVoiceClient(configuration: configuration, session: session)
    }

    private static func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cosyvoice-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createFakeInstall(home: URL) throws {
        let fileManager = FileManager.default
        let venv = CosyVoiceInstallation.venvPythonURL(home: home)
        try fileManager.createDirectory(
            at: venv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: venv)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: venv.path)

        let modelDirectory = CosyVoiceInstallation.modelDirectory(home: home)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        for name in [
            "llm.pt", "flow.pt", "hift.pt", "speech_tokenizer_v3.onnx",
            "campplus.onnx", "cosyvoice3.yaml",
        ] {
            try Data().write(to: modelDirectory.appendingPathComponent(name))
        }
        try fileManager.createDirectory(
            at: CosyVoiceInstallation.voicesDirectory(home: home),
            withIntermediateDirectories: true)
        try Data(#"{"version":1}"#.utf8)
            .write(to: CosyVoiceInstallation.markerURL(home: home))
    }

    private func makeFakeInstallScript(body: String) throws -> URL {
        let url = Self.makeTempDirectory().appendingPathComponent("install_cosyvoice.sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static func readyHealthJSON() -> Data {
        Data("""
        {"ok":true,"ready":true,"model":"Fun-CosyVoice3-0.5B-2512",
         "sample_rate":24000,"voices":["girl","loli","onee"],
         "voices_detail":[{"id":"girl","name":"少女"},{"id":"loli","name":"萝莉"},
                          {"id":"onee","name":"御姐"}],
         "device":"mps"}
        """.utf8)
    }

    /// 生成 24k/16k 单声道 PCM16 WAV（测试桩，不依赖 AVAudioFile）。
    private static func makePCM16WAV(
        samples: [Float],
        sampleRate: Int,
        channels: Int = 1
    ) -> Data {
        let frames = samples.count / max(1, channels)
        var dataBytes = Data()
        for index in 0..<frames {
            for channel in 0..<channels {
                let value = samples[index * channels + channel]
                let clamped = max(-1, min(1, value))
                let raw = Int16(clamped * 32_767)
                withUnsafeBytes(of: raw.littleEndian) { dataBytes.append(contentsOf: $0) }
            }
        }
        var data = Data()
        func appendU16(_ value: Int, to data: inout Data) {
            var little = UInt16(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendU32(_ value: Int, to data: inout Data) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        appendU32(36 + dataBytes.count, to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendU32(16, to: &data)
        appendU16(1, to: &data)
        appendU16(channels, to: &data)
        appendU32(sampleRate, to: &data)
        appendU32(sampleRate * channels * 2, to: &data)
        appendU16(channels * 2, to: &data)
        appendU16(16, to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendU32(dataBytes.count, to: &data)
        data.append(dataBytes)
        return data
    }

    // MARK: - 音色库测试辅助

    private func makeVoiceStore(voicesDirectory: URL) -> CosyVoiceVoiceStore {
        CosyVoiceVoiceStore(
            voicesDirectory: voicesDirectory,
            client: makeClient(),
            serviceReady: { false }
        )
    }

    /// 生成内置三音色 + 带未知字段的 voices.json 夹具。
    private func makeVoicesFixture() throws -> URL {
        let directory = Self.makeTempDirectory()
        var entries: [[String: Any]] = []
        for (id, name) in [("girl", "少女"), ("loli", "萝莉"), ("onee", "御姐")] {
            let voiceDirectory = directory.appendingPathComponent(id)
            try FileManager.default.createDirectory(
                at: voiceDirectory, withIntermediateDirectories: true)
            let audio = try makeAudioFile(
                in: voiceDirectory, seconds: 6, amplitude: 0.4,
                fileName: "prompt.wav")
            _ = audio
            try Data("内置参考文本 \(id)。".utf8)
                .write(to: voiceDirectory.appendingPathComponent("prompt.txt"))
            try Data(#"{"id":"\#(id)","name":"\#(name)","builtin":true}"#.utf8)
                .write(to: voiceDirectory.appendingPathComponent("meta.json"))
            var entry: [String: Any] = [
                "id": id,
                "name": name,
                "description": "\(name)内置音色",
                "prompt_wav": "\(id)/prompt.wav",
                "prompt_text": "内置参考文本 \(id)。",
                "mode": "zero_shot",
                "personal_use_only": true,
                "builtin": true,
                "duration": 6.0,
                "source": "builtin",
            ]
            if id == "girl" { entry["custom_field"] = "keep-voice" }
            entries.append(entry)
        }
        let manifest: [String: Any] = [
            "version": 1,
            "unknown_root": "keep-me",
            "voices": entries,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("voices.json"), options: .atomic)
        return directory
    }

    /// 旧布局（只有 prompt.wav/prompt.txt、manifest 无 references）的自定义音色。
    private func makeLegacyCustomVoice(
        in fixture: URL,
        id: String,
        name: String,
        text: String
    ) throws {
        let directory = fixture.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        _ = try makeAudioFile(
            in: directory, seconds: 6, amplitude: 0.4, fileName: "prompt.wav")
        try Data(text.utf8)
            .write(to: directory.appendingPathComponent("prompt.txt"))
        try Data(#"{"id":"\#(id)","name":"\#(name)","mode":"zero_shot"}"#.utf8)
            .write(to: directory.appendingPathComponent("meta.json"))
        let manifestURL = fixture.appendingPathComponent("voices.json")
        var manifest = try readJSONObject(manifestURL)
        var entries = (manifest["voices"] as? [[String: Any]]) ?? []
        entries.append([
            "id": id,
            "name": name,
            "description": "",
            "prompt_wav": "\(id)/prompt.wav",
            "prompt_text": text,
            "mode": "zero_shot",
            "personal_use_only": true,
            "builtin": false,
            "duration": 6.0,
            "source": "app-import",
        ])
        manifest["voices"] = entries
        let data = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
    }

    /// 生成指定时长/幅度的 16k mono WAV（store 内部会转 24k）。
    private func makeAudioFile(
        in directory: URL,
        seconds: Double,
        amplitude: Float,
        fileName: String? = nil
    ) throws -> URL {
        let sampleRate = 16_000
        let count = Int(Double(sampleRate) * seconds)
        let samples = (0..<count).map { index in
            Float(sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate))) * amplitude
        }
        let data = Self.makePCM16WAV(samples: samples, sampleRate: sampleRate)
        let url = directory.appendingPathComponent(
            fileName ?? "audio-\(UUID().uuidString).wav")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: 导出 zip 测试辅助

    private func zipEntries(_ url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "zipEntries", code: Int(process.terminationStatus))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("__MACOSX") }
    }

    private func readZipEntry(_ url: URL, path: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "readZipEntry", code: Int(process.terminationStatus))
        }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - Fake URLProtocol

/// 可注入的 URLSession 桩：测试 health/voices/tts 的请求与错误映射。
final class FakeCosyVoiceURLProtocol: URLProtocol {
    enum Response {
        case http(status: Int, body: Data, headers: [String: String])
        case failure(Error)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> Response)?
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []

    static func setHandler(_ handler: @escaping (URLRequest) throws -> Response) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        recordedRequests.removeAll()
        lock.unlock()
    }

    static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            switch try handler(request) {
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .http(let status, let body, let headers):
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "http://127.0.0.1:5051")!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Fake process / launcher

final class FakeCosyVoiceProcess: CosyVoiceLaunchedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private var exitHandler: (@Sendable (Int32) -> Void)?
    let pid: Int32
    private(set) var terminateCount = 0

    init(pid: Int32 = 4_242, running: Bool = true) {
        self.pid = pid
        self.running = running
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func terminate() {
        lock.lock()
        terminateCount += 1
        running = false
        let handler = exitHandler
        exitHandler = nil
        lock.unlock()
        handler?(0)
    }

    func forceKill() {
        terminate()
    }

    func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        exitHandler = handler
        lock.unlock()
    }

    func exit(_ status: Int32) {
        lock.lock()
        running = false
        let handler = exitHandler
        exitHandler = nil
        lock.unlock()
        handler?(status)
    }
}

final class FakeCosyVoiceLauncher: CosyVoiceServerLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var launches = 0
    private var lastArguments: [String] = []
    private let factory: () throws -> FakeCosyVoiceProcess
    private var process: FakeCosyVoiceProcess?

    init(factory: @escaping () throws -> FakeCosyVoiceProcess = { FakeCosyVoiceProcess() }) {
        self.factory = factory
    }

    var launchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return launches
    }

    func launch(
        script: URL,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any CosyVoiceLaunchedProcess {
        let created = try factory()
        created.onExit(onExit)
        lock.lock()
        launches += 1
        lastArguments = arguments
        process = created
        lock.unlock()
        onLine("fake server started")
        return created
    }
}

// MARK: - Manual clock

final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        lock.unlock()
    }
}
