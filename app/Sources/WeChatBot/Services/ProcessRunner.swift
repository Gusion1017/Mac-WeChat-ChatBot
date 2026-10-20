import Foundation

// MARK: - Process output

enum ProcessStreamKind: Sendable {
    case stdout
    case stderr
}

enum ProcessStreamEvent: Sendable {
    case line(String, ProcessStreamKind)
    case terminated(Int32)
}

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum ProcessRunnerError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        if case .launchFailed(let message) = self { return "进程启动失败：\(message)" }
        return "进程启动失败"
    }
}

/// Async wrapper around Foundation `Process` used for hook scripts and the bridge.
///
/// Output is streamed line-by-line from dedicated background readers (no pipe-buffer
/// deadlocks). The caller consumes `AsyncThrowingStream` from any actor; actual IO never
/// happens on the main actor.
///
/// Lifecycle notes (crash regression, QA kill/restart):
/// - `Process.terminationStatus` is only read inside `Process.terminationHandler`, where
///   Foundation guarantees the task has exited. Reading it after `terminate()` while the
///   task is still running raises `NSInvalidArgumentException: task still running`.
/// - The event stream finishes exactly once after **both** pipe readers reach EOF and the
///   termination handler fires. Cancellation (`onTermination`) only requests SIGTERM; it
///   never reads process status synchronously.
/// - Pipe readers start only after a successful `run()`, so a failed launch cannot leave
///   blocked reader threads behind.
enum ProcessRunner {
    struct StreamHandle {
        var process: Process
        var events: AsyncThrowingStream<ProcessStreamEvent, Error>
    }

    /// Launches a process and returns a handle for streaming output + termination control.
    static func launch(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) -> StreamHandle {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = LineBuffer()
        let stderrBuffer = LineBuffer()

        let events = AsyncThrowingStream<ProcessStreamEvent, Error> { continuation in
            let lifecycle = ProcessLifecycle(process: process, continuation: continuation)
            continuation.onTermination = { _ in
                lifecycle.cancel()
            }
            process.terminationHandler = { finishedProcess in
                lifecycle.processExited(status: finishedProcess.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                // No readers were started yet; close parent write ends so nothing leaks.
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                lifecycle.launchFailed(error)
                return
            }
            lifecycle.markLaunched()

            DispatchQueue.global(qos: .utility).async {
                let handle = stdoutPipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    for line in stdoutBuffer.append(data) {
                        continuation.yield(.line(line, .stdout))
                    }
                }
                if let remainder = stdoutBuffer.flush() {
                    continuation.yield(.line(remainder, .stdout))
                }
                lifecycle.readerFinished()
            }

            DispatchQueue.global(qos: .utility).async {
                let handle = stderrPipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    for line in stderrBuffer.append(data) {
                        continuation.yield(.line(line, .stderr))
                    }
                }
                if let remainder = stderrBuffer.flush() {
                    continuation.yield(.line(remainder, .stderr))
                }
                lifecycle.readerFinished()
            }
        }

        return StreamHandle(process: process, events: events)
    }

    /// Convenience for short commands (otool / pgrep / codesign). Collects all output.
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        let handle = launch(executable: executable, arguments: arguments,
                            currentDirectory: currentDirectory, environment: environment)
        var stdout = ""
        var stderr = ""
        var status: Int32 = -1
        for try await event in handle.events {
            switch event {
            case .line(let line, .stdout):
                stdout += line + "\n"
            case .line(let line, .stderr):
                stderr += line + "\n"
            case .terminated(let code):
                status = code
            }
        }
        return ProcessResult(status: status, stdout: stdout, stderr: stderr)
    }
}

// MARK: - Lifecycle

/// Guards the single-finish contract of the event stream. Members are called from
/// different queues (Foundation termination handler, pipe readers, consumer cancellation),
/// so all state is lock-protected. It never reads `terminationStatus` itself.
private final class ProcessLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let continuation: AsyncThrowingStream<ProcessStreamEvent, Error>.Continuation

    private var launched = false
    private var cancelled = false
    private var exited = false
    private var exitStatus: Int32 = -1
    private var readersFinished = 0
    private var finished = false

    init(process: Process,
         continuation: AsyncThrowingStream<ProcessStreamEvent, Error>.Continuation) {
        self.process = process
        self.continuation = continuation
    }

    func markLaunched() {
        lock.lock()
        launched = true
        let mustCancel = cancelled
        lock.unlock()
        if mustCancel { terminateIfRunning() }
    }

    /// Called from `onTermination` (consumer cancelled or stream deallocated).
    /// Requests termination only; the exit status is reported later by `processExited`.
    func cancel() {
        lock.lock()
        cancelled = true
        let shouldTerminate = launched && !exited
        lock.unlock()
        if shouldTerminate { terminateIfRunning() }
    }

    func readerFinished() {
        lock.lock()
        readersFinished += 1
        let ready = readersFinished >= 2
        lock.unlock()
        if ready { finalizeIfReady() }
    }

    /// Called from `Process.terminationHandler` — the only safe place to read status.
    func processExited(status: Int32) {
        lock.lock()
        exited = true
        exitStatus = status
        lock.unlock()
        finalizeIfReady()
    }

    func launchFailed(_ error: Error) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        exited = true
        lock.unlock()
        continuation.finish(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
    }

    private func terminateIfRunning() {
        // `isRunning` is safe to query at any time; `terminate()` raises if the task
        // already exited, so re-check immediately before signalling.
        guard process.isRunning else { return }
        process.terminate()
    }

    private func finalizeIfReady() {
        lock.lock()
        guard !finished, exited, readersFinished >= 2 else {
            lock.unlock()
            return
        }
        finished = true
        let status = exitStatus
        lock.unlock()

        continuation.yield(.terminated(status))
        continuation.finish()
    }
}

/// Splits streamed bytes into complete lines. Thread-safe: reader callbacks may run
/// concurrently for stdout/stderr.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        buffer += text
        var lines: [String] = []
        while let index = buffer.firstIndex(of: "\n") {
            var line = String(buffer[buffer.startIndex..<index])
            if line.hasSuffix("\r") { line.removeLast() }
            buffer.removeSubrange(buffer.startIndex...index)
            lines.append(line)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remainder.isEmpty ? nil : remainder
    }
}
