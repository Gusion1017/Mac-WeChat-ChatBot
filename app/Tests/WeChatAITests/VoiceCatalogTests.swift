import XCTest

@testable import WeChatAI

/// Kokoro 音色目录与引擎模型计划（2026-10-27）。
///
/// 音色目录是官方 sid → name 映射的固化；这里锁定数量、分组、顺序与越界收敛，
/// 防止以后改设置页时把 `zf_001` 之类的编号写错，或误用旧的 `voices.bin / 512` 推导。
final class VoiceCatalogTests: XCTestCase {
    // MARK: - 音色目录

    func testCatalogMatchesOfficial103Voices() {
        XCTAssertEqual(KokoroVoiceCatalog.count, 103)
        XCTAssertEqual(KokoroVoiceCatalog.all.map(\.sid), Array(0..<103))
        XCTAssertEqual(Set(KokoroVoiceCatalog.all.map(\.name)).count, 103, "音色名必须唯一")
        XCTAssertEqual(KokoroVoiceCatalog.all.first?.name, "af_maple")
        XCTAssertEqual(KokoroVoiceCatalog.all.last?.name, "zm_100")
    }

    func testGroupRangesAndCounts() {
        XCTAssertEqual(KokoroVoiceCatalog.voices(in: .englishFemale).count, 3)
        XCTAssertEqual(KokoroVoiceCatalog.voices(in: .chineseFemale).count, 55)
        XCTAssertEqual(KokoroVoiceCatalog.voices(in: .chineseMale).count, 45)

        XCTAssertEqual(KokoroVoiceCatalog.all[0].group, .englishFemale)
        XCTAssertEqual(KokoroVoiceCatalog.all[1].group, .englishFemale)
        XCTAssertEqual(KokoroVoiceCatalog.all[2].group, .englishFemale)
        XCTAssertEqual(KokoroVoiceCatalog.all[3].group, .chineseFemale)
        XCTAssertEqual(KokoroVoiceCatalog.all[57].group, .chineseFemale)
        XCTAssertEqual(KokoroVoiceCatalog.all[58].group, .chineseMale)
        XCTAssertEqual(KokoroVoiceCatalog.all[102].group, .chineseMale)

        for group in KokoroVoiceGroup.allCases {
            XCTAssertEqual(
                KokoroVoiceCatalog.voices(in: group).count,
                group.count,
                "\(group.rawValue) 的硬编码数量与目录不一致"
            )
        }
    }

    func testLookupAndClamp() {
        XCTAssertEqual(KokoroVoiceCatalog.voice(for: 3)?.name, "zf_001")
        XCTAssertEqual(KokoroVoiceCatalog.displayName(for: 58), "zm_009")
        XCTAssertNil(KokoroVoiceCatalog.voice(for: -1))
        XCTAssertNil(KokoroVoiceCatalog.voice(for: 103))
        XCTAssertEqual(KokoroVoiceCatalog.displayName(for: 999), "#999")

        XCTAssertEqual(KokoroVoiceCatalog.clampedSpeakerID(-5), 0)
        XCTAssertEqual(KokoroVoiceCatalog.clampedSpeakerID(0), 0)
        XCTAssertEqual(KokoroVoiceCatalog.clampedSpeakerID(3), 3)
        XCTAssertEqual(KokoroVoiceCatalog.clampedSpeakerID(102), 102)
        XCTAssertEqual(KokoroVoiceCatalog.clampedSpeakerID(999), 102)
    }

    func testSearchTextCoversNameAndGroup() {
        let voice = KokoroVoiceCatalog.voice(for: 3)!
        XCTAssertTrue(voice.searchText.contains("zf_001"))
        XCTAssertTrue(voice.searchText.contains("中文"))
        XCTAssertTrue(voice.searchText.localizedCaseInsensitiveContains("chinese"))
    }

    // MARK: - 设置收敛

    func testVoiceSettingsClampsKokoroSpeakerID() throws {
        var voice = VoiceSettings()
        voice.kokoroSpeakerID = 999
        let data = try JSONEncoder().encode(voice)
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: data)
        XCTAssertEqual(decoded.kokoroSpeakerID, 102, "手改配置的超界 sid 必须收敛")
        XCTAssertEqual(decoded.effectiveKokoroSpeakerID, 102)

        var negative = VoiceSettings()
        negative.kokoroSpeakerID = -3
        let negativeDecoded = try JSONDecoder().decode(
            VoiceSettings.self,
            from: JSONEncoder().encode(negative)
        )
        XCTAssertEqual(negativeDecoded.kokoroSpeakerID, 0)
    }

    func testVoiceSelectionUsesClampedSpeaker() {
        var settings = VoiceSettings()
        settings.kokoroSpeakerID = 999
        let selection = VoiceSelection(settings: settings)
        XCTAssertEqual(selection.kokoroSpeakerID, 102)
        XCTAssertEqual(selection.effectiveSpeakerID, 102)

        let direct = VoiceSelection(engine: .kokoro, kokoroSpeakerID: 300, speed: 1.0)
        XCTAssertEqual(direct.effectiveSpeakerID, 102)
    }

    // MARK: - 引擎模型计划

    func testEngineModelPlan() {
        XCTAssertEqual(VoiceEngineKind.kokoro.requiredModels, [.kokoro])
        XCTAssertEqual(VoiceEngineKind.zipvoiceClone.requiredModels, [.zipvoice, .vocoder])
        XCTAssertTrue(VoiceEngineKind.kokoro.requiredModels.allSatisfy { kind in
            VoiceModelStore.catalog.contains { $0.kind == kind }
        })
        XCTAssertTrue(VoiceEngineKind.zipvoiceClone.requiredModels.allSatisfy { kind in
            VoiceModelStore.catalog.contains { $0.kind == kind }
        })
    }

    @MainActor
    func testEngineStatusIsInternallyConsistent() {
        for engine in VoiceEngineKind.allCases {
            let status = VoiceModelStore.shared.status(for: engine)
            XCTAssertEqual(status.kinds, engine.requiredModels)
            XCTAssertEqual(status.missing.count + status.readyKinds.count, status.kinds.count)
            XCTAssertTrue((0...1).contains(status.progress))
            XCTAssertEqual(status.isReady, status.missing.isEmpty)
            XCTAssertLessThanOrEqual(status.missingBytes, status.totalBytes)
        }
    }
}
