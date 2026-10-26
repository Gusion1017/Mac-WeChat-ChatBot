import AVFoundation
import Foundation

// MARK: - Errors

enum VoiceSynthesisAudioError: Error, LocalizedError, Equatable {
    case unreadableAudio(String)
    case converterUnavailable
    case conversionFailed(String)
    case emptyAudio
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableAudio(let path): return "无法读取音频：\(path)"
        case .converterUnavailable: return "音频转换器不可用"
        case .conversionFailed(let reason): return "音频重采样失败：\(reason)"
        case .emptyAudio: return "音频内容为空"
        case .writeFailed(let reason): return "音频写入失败：\(reason)"
        }
    }
}

// MARK: - Audio helpers

/// TTS 输出/参考音频的音频处理层（spec §3.1：sherpa 24k → AVAudioConverter → 16k）。
///
/// 统一约定：
/// - 语音合成产物是 **16 kHz 单声道 16-bit WAV**（微信 SILK 链路按 16k PCM 编码）；
/// - 内部计算都用 float 单声道，写盘交给 `AVAudioFile`（它会按 settings 落成 16-bit PCM）；
/// - 克隆参考音频导入时用同一个转换器做「多声道 → 单声道 + 任意采样率 → 16k」。
enum VoiceSynthesisAudio {
    /// 输出/参考音频统一采样率。
    static let targetSampleRate = 16_000
    /// 克隆参考音频最长时长（超过会截断，避免合成前处理过长）。
    static let maxReferenceSeconds: TimeInterval = 30

    // MARK: 24k → 16k（TTS 主链路）

    /// 把任意采样率的单声道 float PCM 重采样到 16 kHz（AVAudioConverter）。
    static func resampleTo16k(_ samples: [Float], sampleRate: Int) throws -> [Float] {
        guard !samples.isEmpty else { throw VoiceSynthesisAudioError.emptyAudio }
        guard sampleRate > 0 else { throw VoiceSynthesisAudioError.emptyAudio }
        if sampleRate == targetSampleRate { return samples }

        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        )!
        let input = try makeBuffer(samples: samples, format: inputFormat)
        return try convert(input, to: outputFormat, element: .float)
    }

    // MARK: 写 WAV

    /// 写 16 kHz 单声道 16-bit PCM WAV（兼容旧调用；克隆参考/单测用）。
    @discardableResult
    static func writePCM16WAV(samples: [Float], to url: URL) throws -> URL {
        try writePCM16WAV(samples: samples, sampleRate: targetSampleRate, to: url)
    }

    /// 按指定采样率写单声道 16-bit PCM WAV（Kokoro/ZipVoice 原生 24k 直通）。
    @discardableResult
    static func writePCM16WAV(samples: [Float], sampleRate: Int, to url: URL) throws -> URL {
        guard !samples.isEmpty else { throw VoiceSynthesisAudioError.emptyAudio }
        guard sampleRate > 0 else { throw VoiceSynthesisAudioError.writeFailed("采样率无效") }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ) else {
                throw VoiceSynthesisAudioError.writeFailed("无法分配输出缓冲")
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            guard let channel = buffer.floatChannelData?[0] else {
                throw VoiceSynthesisAudioError.writeFailed("输出缓冲格式不是 float")
            }
            let clamped = samples.map { max(-1, min(1, $0)) }
            clamped.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
        } catch let error as VoiceSynthesisAudioError {
            throw error
        } catch {
            throw VoiceSynthesisAudioError.writeFailed(error.localizedDescription)
        }
        return url
    }

    // MARK: 读取（克隆参考音频 / 单测）

    /// 读取 wav/m4a 等任意 `AVAudioFile` 支持的文件，转成 16 kHz 单声道 float。
    /// `maxSeconds != nil` 时只保留前 N 秒。
    static func decodeMono16k(url: URL, maxSeconds: TimeInterval? = nil) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw VoiceSynthesisAudioError.unreadableAudio(url.path)
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { throw VoiceSynthesisAudioError.emptyAudio }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw VoiceSynthesisAudioError.unreadableAudio(url.path)
        }
        do {
            try file.read(into: input)
        } catch {
            throw VoiceSynthesisAudioError.unreadableAudio(url.path)
        }

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        )!
        var samples = try convert(input, to: outputFormat, element: .float)
        if let maxSeconds, maxSeconds > 0,
           Double(samples.count) / Double(targetSampleRate) > maxSeconds {
            let limit = Int(maxSeconds * Double(targetSampleRate))
            samples = Array(samples.prefix(limit))
        }
        guard !samples.isEmpty else { throw VoiceSynthesisAudioError.emptyAudio }
        return samples
    }

    /// 直接解析 RIFF/WAVE 头（采样率/声道/位深/时长），单测与自检用。
    ///
    /// 不依赖 AVAudioFile 的松散字典类型，确保断言的是**文件里真实写入**的格式。
    static func wavMetadata(url: URL) throws -> (
        sampleRate: Int, channels: Int, bitsPerSample: Int, duration: TimeInterval
    ) {
        let data = try Data(contentsOf: url)
        guard data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw VoiceSynthesisAudioError.unreadableAudio(url.path)
        }
        func u16(_ offset: Int) -> Int {
            Int(data[offset]) | (Int(data[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> Int {
            Int(data[offset]) | (Int(data[offset + 1]) << 8)
                | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
        }
        // 逐块解析：AVAudioFile 会在标准头前插入 `JUNK`/`FLLR` 填充块，
        // 因此不能假设 fmt 一定在偏移 12、data 一定在偏移 44。
        var fmtOffset = -1
        var dataBytes = 0
        var offset = 12
        while offset + 8 <= data.count {
            let identifier = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            if identifier == "fmt " {
                fmtOffset = offset + 8
            } else if identifier == "data" {
                dataBytes = min(size, max(0, data.count - (offset + 8)))
            }
            offset += 8 + size + (size % 2)
        }
        guard fmtOffset >= 0, fmtOffset + 16 <= data.count else {
            throw VoiceSynthesisAudioError.unreadableAudio(url.path)
        }
        let audioFormat = u16(fmtOffset)
        let channels = u16(fmtOffset + 2)
        let sampleRate = u32(fmtOffset + 4)
        let bits = u16(fmtOffset + 14)
        let bytesPerFrame = max(1, channels * (bits / 8))
        let duration = sampleRate > 0
            ? Double(dataBytes) / Double(bytesPerFrame) / Double(sampleRate)
            : 0
        return (sampleRate, channels, bits, duration)
    }

    // MARK: 内部

    private enum SampleElement { case float }

    private static func makeBuffer(samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw VoiceSynthesisAudioError.conversionFailed("无法分配输入缓冲")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw VoiceSynthesisAudioError.conversionFailed("输入缓冲格式不是 float")
        }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// 用 `AVAudioConverter` 完成「重采样 + 声道下混 + 格式统一」，收集所有输出块。
    private static func convert(
        _ input: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat,
        element: SampleElement
    ) throws -> [Float] {
        _ = element
        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            throw VoiceSynthesisAudioError.converterUnavailable
        }
        // 一次性喂满输入；输入耗尽后再返回 endOfStream，让转换器把内部残留冲出来。
        var supplied = false
        var finished = false
        var chunks: [Float] = []
        chunks.reserveCapacity(
            Int(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate) + 1024)

        var rounds = 0
        while !finished {
            rounds += 1
            if rounds > 100_000 { throw VoiceSynthesisAudioError.conversionFailed("转换未收敛") }
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_384) else {
                throw VoiceSynthesisAudioError.conversionFailed("无法分配输出缓冲")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return input
            }
            if let error {
                throw VoiceSynthesisAudioError.conversionFailed(error.localizedDescription)
            }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                chunks.append(
                    contentsOf: UnsafeBufferPointer(
                        start: channel, count: Int(output.frameLength)))
            }
            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                finished = true
            case .error:
                throw VoiceSynthesisAudioError.conversionFailed("转换器返回错误")
            @unknown default:
                finished = true
            }
        }
        guard !chunks.isEmpty else { throw VoiceSynthesisAudioError.emptyAudio }
        return chunks
    }
}
