//
//  SherpaOnnxTTS.swift
//  WeChatAI
//
//  Minimal Swift bridge for the vendored sherpa-onnx offline TTS C API.
//  Adapted from the official `swift-api-examples/SherpaOnnx.swift`
//  (https://github.com/k2-fsa/sherpa-onnx, tag v2.0.0).
//
//  Copyright (c)  2023  Xiaomi Corporation
//  Licensed under the Apache License, Version 2.0.
//  See ThirdPartyNotices.txt at the repository root for the full notice.
//
//  Scope: only the parts needed by `VoiceSynthesisService`:
//  - build an offline TTS engine for Kokoro (multi-lang, built-in speakers) or
//    ZipVoice (zero-shot voice cloning) from the vendored static library;
//  - generate mono float PCM with a full generation config
//    (sid / speed / reference audio / reference text / num_steps / extra JSON);
//  - read and write 16-bit PCM WAV files through the C API.
//
//  The C API copies every `const char *` into a C++ `std::string` while it runs,
//  so the temporary C strings created here are released as soon as the C call
//  returns (`CStringArena`). That keeps repeated synthesis leak-free, unlike the
//  upstream example that `strdup`s per call and never frees.
//

import Foundation
import CSherpaOnnx

// MARK: - Errors

enum SherpaTtsEngineError: Error, LocalizedError, Equatable {
    /// `SherpaOnnxCreateOfflineTts` returned NULL (bad paths / incompatible model).
    case engineCreationFailed(String)
    /// `SherpaOnnxOfflineTtsGenerateWithConfig` returned NULL (e.g. rejected text).
    case generationFailed
    /// `SherpaOnnxReadWave` failed (missing file or unsupported WAV layout).
    case waveReadFailed(String)
    /// `SherpaOnnxWriteWave` returned a non-success status.
    case waveWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineCreationFailed(let detail):
            return "语音引擎初始化失败：\(detail)"
        case .generationFailed:
            return "语音合成失败"
        case .waveReadFailed(let path):
            return "无法读取参考音频：\(path)"
        case .waveWriteFailed(let path):
            return "无法写入语音文件：\(path)"
        }
    }
}

// MARK: - Engine configuration

/// Kokoro multi-lang model files (built-in speaker voices).
struct SherpaTtsKokoroConfig: Sendable, Equatable {
    var model: String
    var voices: String
    var tokens: String
    /// Comma-separated lexicon list, e.g. `lexicon-us-en.txt,lexicon-zh.txt`.
    var lexicon: String
    /// Optional language hint (`en`, `zh`, ...); empty lets the model decide.
    var lang: String = ""
    /// Comma-separated text-normalization FSTs, e.g.
    /// `date-zh.fst,phone-zh.fst,number-zh.fst`. The order matters:
    /// `phone-zh.fst` must run before `number-zh.fst`, otherwise a phone number
    /// is read as one huge cardinal number.
    var ruleFsts: String = ""
    /// Speech-rate scale; values < 1 are slower.
    var lengthScale: Float = 1.0
}

/// ZipVoice distill model files (zero-shot voice cloning).
struct SherpaTtsZipvoiceConfig: Sendable, Equatable {
    var tokens: String
    var encoder: String
    var decoder: String
    var vocoder: String
    /// Comma-separated lexicon list.
    var lexicon: String
    var featScale: Float = 0.1
    var tShift: Float = 0.5
    var targetRMS: Float = 0.1
    var guidanceScale: Float = 1.0
}

/// Per-call generation parameters (mirrors `SherpaOnnxGenerationConfig`).
struct SherpaTtsGenerationConfig: Sendable, Equatable {
    var speed: Float = 1.0
    var speakerID: Int = 0
    var silenceScale: Float = 0.2
    /// Reference (clone) audio; only used by ZipVoice.
    var referenceAudio: [Float] = []
    var referenceSampleRate: Int = 0
    /// Transcript of `referenceAudio`; ZipVoice needs it to align the clone.
    var referenceText: String = ""
    /// Flow-matching steps (ZipVoice); 4 is the distilled default.
    var numSteps: Int = 4
    /// Model-specific extras, serialized to JSON (`min_char_in_sentence`, ...).
    var extra: [String: String] = [:]
}

/// Mono float PCM produced by the engine.
struct SherpaGeneratedAudio: Sendable, Equatable {
    var samples: [Float]
    var sampleRate: Int

    var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
    }
}

// MARK: - Helpers

/// Keeps the C strings alive for exactly one C API call, then frees them.
private final class CStringArena {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    func str(_ value: String) -> UnsafePointer<CChar>? {
        guard let pointer = strdup(value) else { return nil }
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }

    deinit {
        for pointer in pointers {
            free(pointer)
        }
    }
}

// MARK: - Engine

/// Owns one `SherpaOnnxOfflineTts` handle. Not thread-safe: callers (the
/// `VoiceSynthesisService` actor) serialize access.
final class SherpaTtsEngine {
    private let handle: OpaquePointer

    /// Output sample rate advertised by the model (24 kHz for Kokoro/ZipVoice).
    var sampleRate: Int { Int(SherpaOnnxOfflineTtsSampleRate(handle)) }

    /// Number of built-in speakers (Kokoro: 103; ZipVoice: 1).
    var numSpeakers: Int { Int(SherpaOnnxOfflineTtsNumSpeakers(handle)) }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        SherpaOnnxDestroyOfflineTts(handle)
    }

    // MARK: Constructors

    static func makeKokoro(
        _ config: SherpaTtsKokoroConfig,
        numThreads: Int = 2,
        provider: String = "cpu"
    ) throws -> SherpaTtsEngine {
        let arena = CStringArena()
        var modelConfig = SherpaOnnxOfflineTtsModelConfig()
        modelConfig.num_threads = Int32(numThreads)
        modelConfig.debug = 0
        modelConfig.provider = arena.str(provider)
        modelConfig.kokoro.model = arena.str(config.model)
        modelConfig.kokoro.voices = arena.str(config.voices)
        modelConfig.kokoro.tokens = arena.str(config.tokens)
        modelConfig.kokoro.lexicon = arena.str(config.lexicon)
        modelConfig.kokoro.lang = arena.str(config.lang)
        modelConfig.kokoro.length_scale = config.lengthScale

        var ttsConfig = SherpaOnnxOfflineTtsConfig()
        ttsConfig.model = modelConfig
        ttsConfig.max_num_sentences = 1
        // 0.2 会把 >0.2s 的句读停顿压到 20%，整段合成时听起来会“喘不上气”。
        ttsConfig.silence_scale = 0.8
        if !config.ruleFsts.isEmpty {
            ttsConfig.rule_fsts = arena.str(config.ruleFsts)
        }

        return try create(&ttsConfig, describe: config.model)
    }

    static func makeZipvoice(
        _ config: SherpaTtsZipvoiceConfig,
        numThreads: Int = 2,
        provider: String = "cpu"
    ) throws -> SherpaTtsEngine {
        let arena = CStringArena()
        var modelConfig = SherpaOnnxOfflineTtsModelConfig()
        modelConfig.num_threads = Int32(numThreads)
        modelConfig.debug = 0
        modelConfig.provider = arena.str(provider)
        modelConfig.zipvoice.tokens = arena.str(config.tokens)
        modelConfig.zipvoice.encoder = arena.str(config.encoder)
        modelConfig.zipvoice.decoder = arena.str(config.decoder)
        modelConfig.zipvoice.vocoder = arena.str(config.vocoder)
        modelConfig.zipvoice.lexicon = arena.str(config.lexicon)
        modelConfig.zipvoice.feat_scale = config.featScale
        modelConfig.zipvoice.t_shift = config.tShift
        modelConfig.zipvoice.target_rms = config.targetRMS
        modelConfig.zipvoice.guidance_scale = config.guidanceScale

        var ttsConfig = SherpaOnnxOfflineTtsConfig()
        ttsConfig.model = modelConfig
        ttsConfig.max_num_sentences = 1
        ttsConfig.silence_scale = 0.8

        return try create(&ttsConfig, describe: config.encoder)
    }

    private static func create(
        _ config: inout SherpaOnnxOfflineTtsConfig,
        describe path: String
    ) throws -> SherpaTtsEngine {
        guard let handle = SherpaOnnxCreateOfflineTts(&config) else {
            throw SherpaTtsEngineError.engineCreationFailed(path)
        }
        return SherpaTtsEngine(handle: handle)
    }

    // MARK: Generation

    /// Synthesize `text` into mono float PCM.
    func generate(text: String, config: SherpaTtsGenerationConfig) throws -> SherpaGeneratedAudio {
        let arena = CStringArena()

        var cConfig = SherpaOnnxGenerationConfig()
        cConfig.silence_scale = config.silenceScale
        cConfig.speed = config.speed
        cConfig.sid = Int32(config.speakerID)
        cConfig.reference_sample_rate = Int32(config.referenceSampleRate)
        cConfig.reference_text = arena.str(config.referenceText)
        cConfig.num_steps = Int32(config.numSteps)
        cConfig.extra = arena.str(Self.jsonString(config.extra))
        let textPointer = arena.str(text)

        let audioPointer: UnsafePointer<SherpaOnnxGeneratedAudio>? =
            config.referenceAudio.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress, !buffer.isEmpty {
                    cConfig.reference_audio = base
                    cConfig.reference_audio_len = Int32(buffer.count)
                }
                return SherpaOnnxOfflineTtsGenerateWithConfig(handle, textPointer, &cConfig, nil, nil)
            }

        guard let audioPointer else {
            throw SherpaTtsEngineError.generationFailed
        }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audioPointer) }

        let count = Int(audioPointer.pointee.n)
        let samples: [Float]
        if let raw = audioPointer.pointee.samples, count > 0 {
            samples = Array(UnsafeBufferPointer(start: raw, count: count))
        } else {
            samples = []
        }
        return SherpaGeneratedAudio(
            samples: samples,
            sampleRate: Int(audioPointer.pointee.sample_rate)
        )
    }

    /// Serialize the `extra` dictionary the way the C API expects.
    /// Only strings are used by the models we ship; an empty dictionary maps to `{}`.
    private static func jsonString(_ extra: [String: String]) -> String {
        guard !extra.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

// MARK: - WAV I/O

enum SherpaWaveIO {
    /// Read a mono WAV into normalized float samples.
    static func read(url: URL) throws -> SherpaGeneratedAudio {
        guard let wave = SherpaOnnxReadWave(url.path) else {
            throw SherpaTtsEngineError.waveReadFailed(url.path)
        }
        defer { SherpaOnnxFreeWave(wave) }
        let count = Int(wave.pointee.num_samples)
        let samples: [Float]
        if let raw = wave.pointee.samples, count > 0 {
            samples = Array(UnsafeBufferPointer(start: raw, count: count))
        } else {
            samples = []
        }
        return SherpaGeneratedAudio(samples: samples, sampleRate: Int(wave.pointee.sample_rate))
    }

    /// Write mono float samples as a 16-bit PCM WAV file.
    @discardableResult
    static func write(samples: [Float], sampleRate: Int, to url: URL) throws -> URL {
        guard sampleRate > 0, !samples.isEmpty else {
            throw SherpaTtsEngineError.waveWriteFailed(url.path)
        }
        let status: Int32 = samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxWriteWave(
                buffer.baseAddress,
                Int32(buffer.count),
                Int32(sampleRate),
                url.path
            )
        }
        guard status > 0 else {
            throw SherpaTtsEngineError.waveWriteFailed(url.path)
        }
        return url
    }
}
