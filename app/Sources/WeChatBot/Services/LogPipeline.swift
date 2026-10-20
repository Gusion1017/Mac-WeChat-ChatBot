import Foundation

// MARK: - ANSI stripping

/// Removes ANSI escape sequences and carriage returns from process/bridge output.
///
/// Bridge stdout is colourised (`\u{1B}[90m…\u{1B}[0m`) and emits several lines per second.
/// Stripping happens on the background pipe-reader threads (`ProcessRunner`) and again,
/// defensively, inside `LogPipeline` so no escape code ever reaches the UI or database.
enum AnsiText {
    static func strip(_ input: String) -> String {
        // Fast path: the vast majority of log lines carry no escape codes.
        guard input.utf8.contains(0x1B) || input.utf8.contains(0x0D) else { return input }
        var output = String()
        output.reserveCapacity(input.utf8.count)
        var scalars = input.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            switch scalar.value {
            case 0x1B:
                skipEscapeSequence(&scalars)
            case 0x0D:
                continue
            default:
                // Drop remaining C0 control characters except tab; keep the text readable.
                if scalar.value < 0x20 && scalar.value != 0x09 { continue }
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// Consumes the rest of an escape sequence after the leading ESC scalar.
    private static func skipEscapeSequence(_ scalars: inout String.UnicodeScalarView.Iterator) {
        guard let introducer = scalars.next() else { return }
        switch introducer {
        case "[":
            // CSI: parameter/intermediate bytes until a final byte in 0x40...0x7E.
            while let scalar = scalars.next() {
                if scalar.value >= 0x40 && scalar.value <= 0x7E { break }
            }
        case "]":
            // OSC: terminated by BEL or ST (ESC \).
            while let scalar = scalars.next() {
                if scalar.value == 0x07 { break }
                if scalar.value == 0x1B {
                    _ = scalars.next()
                    break
                }
            }
        case "(", ")", "*", "+", "-", ".", "/":
            // Charset designation: ESC ( B and friends — one extra byte.
            _ = scalars.next()
        case "P", "^", "_":
            // DCS/SOS/PM/APC: terminated by ST.
            while let scalar = scalars.next() {
                if scalar.value == 0x1B {
                    _ = scalars.next()
                    break
                }
            }
        default:
            // Two-byte sequences such as ESC =, ESC >, ESC 7, ESC 8.
            break
        }
    }
}

// MARK: - Log pipeline

/// Coalescing, thread-safe log sink shared by the whole runtime.
///
/// Producers:
/// - `RuntimeCoordinator.log(_:_:_:)` (main actor),
/// - the detached bridge stdout monitor (background task),
/// - crash watchdogs may post from any thread (`LogPipeline.shared.emit` is nonisolated).
///
/// Behaviour:
/// - ANSI escapes are stripped and messages are length-capped before buffering.
/// - Consecutive identical lines inside a short window are merged into one
///   "重复日志已省略 N 条" entry instead of flooding the buffer.
/// - The observable `store.logs` array is updated in batches at most every
///   `flushInterval` (200 ms) instead of once per produced line, so a 10 lines/s
///   bridge stream causes ≤5 UI invalidations/s instead of 10+.
/// - SQLite writes use the same batches (one transaction per flush), pruning the
///   on-disk ring buffer every `pruneEveryWrites` written entries, as before.
/// - The pending buffer is capped; overflow drops the oldest entries and reports
///   how many were dropped.
final class LogPipeline: @unchecked Sendable {
    static let shared = LogPipeline()

    /// Receives a batch of entries; must be installed from the main actor.
    typealias UIHandler = @MainActor @Sendable ([LogEntry]) -> Void
    typealias DBHandler = @Sendable ([LogEntry]) async -> Void

    static let flushIntervalNanos: UInt64 = 200_000_000
    static let dedupeWindow: TimeInterval = 3
    static let maxPending = 512
    static let maxMessageLength = 2_000
    static let pruneEveryWrites = 100
    static let keepLogs = 5_000

    private let lock = NSLock()
    private var pending: [LogEntry] = []
    private var suppressedDuplicates = 0
    private var lastSignature = ""
    private var lastSignatureDate = Date.distantPast
    private var duplicateLevel: LogLevel = .debug
    private var duplicateSource = ""
    private var droppedEntries = 0
    private var flushScheduled = false
    private var writesSincePrune = 0
    private var uiHandler: UIHandler?
    private var dbHandler: DBHandler?
    private var pruneHandler: (@Sendable () async -> Void)?

    private init() {}

    /// Wires the pipeline to the observable log buffer and the database writer.
    /// Called once from `RuntimeCoordinator.init`; safe to call again on reload.
    @MainActor
    func attach(store: AppStore, memory: MemoryStore = .shared) {
        attach(
            ui: { [weak store] batch in
                store?.appendLogBatch(batch)
            },
            write: { batch in
                try? await memory.appendLogs(batch)
            },
            prune: {
                try? await memory.pruneLogs(keep: LogPipeline.keepLogs)
            }
        )
    }

    /// Lower-level wiring point (UI buffer + database writer + on-disk prune), also
    /// used by tests/tooling to attach an alternative sink.
    @MainActor
    func attach(
        ui: @escaping UIHandler,
        write: @escaping DBHandler,
        prune: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        uiHandler = ui
        dbHandler = write
        pruneHandler = prune
        lock.unlock()
        // Flush anything buffered before the runtime attached (e.g. launch diagnostics).
        startFlushLoopIfNeeded()
    }

    // MARK: Producers

    /// Thread-safe: any actor/thread may log without hopping to the main actor first.
    nonisolated func emit(_ level: LogLevel, _ source: String, _ message: String) {
        let cleaned = AnsiText.strip(message)
        let bounded = cleaned.count > Self.maxMessageLength
            ? String(cleaned.prefix(Self.maxMessageLength)) + "…"
            : cleaned
        let now = Date()
        let signature = "\(level.rawValue)|\(source)|\(bounded)"

        lock.lock()
        if signature == lastSignature,
           now.timeIntervalSince(lastSignatureDate) <= Self.dedupeWindow {
            lastSignatureDate = now
            suppressedDuplicates += 1
            duplicateLevel = level
            duplicateSource = source
            lock.unlock()
            return
        }
        if suppressedDuplicates > 0 {
            pending.append(makeDuplicateSummaryLocked())
            suppressedDuplicates = 0
        }
        lastSignature = signature
        lastSignatureDate = now
        pending.append(LogEntry(level: level, source: source, message: bounded))
        if pending.count > Self.maxPending {
            let overflow = pending.count - Self.maxPending
            pending.removeFirst(overflow)
            droppedEntries += overflow
        }
        startFlushLoopLocked()
        lock.unlock()
    }

    // MARK: Flushing

    /// One coalesced delivery: a batch plus the handlers it should reach.
    private struct FlushJob {
        var batch: [LogEntry]
        var ui: UIHandler?
        var db: DBHandler?
        var prune: (@Sendable () async -> Void)?
    }

    /// Flushes every buffered entry now (used on stop/quit). Waits for the disk write.
    func flushNow() async {
        appendDuplicateSummaryIfNeeded()
        while await flushOnce() {}
    }

    /// Synchronous best-effort flush for `applicationWillTerminate`; the disk write is
    /// queued on a background task so shutdown never blocks on SQLite.
    @MainActor
    func flushForTermination() {
        let batch = takePendingBatch()
        guard !batch.isEmpty else { return }
        uiHandler?(batch)
        if let dbHandler {
            Task { await dbHandler(batch) }
        }
    }

    /// Drops buffered-but-not-yet-visible entries (UI "clear logs").
    func clearPending() {
        lock.lock()
        pending.removeAll()
        suppressedDuplicates = 0
        droppedEntries = 0
        lastSignature = ""
        lastSignatureDate = .distantPast
        lock.unlock()
    }

    /// Number of entries currently waiting for the next flush (diagnostics/tests).
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    private func startFlushLoopIfNeeded() {
        lock.lock()
        startFlushLoopLocked()
        lock.unlock()
    }

    private func startFlushLoopLocked() {
        guard !flushScheduled else { return }
        guard !pending.isEmpty else { return }
        // Before `attach(...)` there is no consumer; keep buffering (bounded) instead of
        // draining entries into the void. `attach` retriggers the loop.
        guard uiHandler != nil || dbHandler != nil else { return }
        flushScheduled = true
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while await self.flushOnce() {
                try? await Task.sleep(nanoseconds: Self.flushIntervalNanos)
                if Task.isCancelled { break }
            }
        }
    }

    /// Delivers one batch to the UI and database. Returns `true` while more work may follow.
    private func flushOnce() async -> Bool {
        guard let job = takeFlushJob() else { return false }
        if let ui = job.ui {
            await ui(job.batch)
        }
        if let db = job.db {
            await db(job.batch)
        }
        if let prune = job.prune {
            await prune()
        }
        return true
    }

    /// Synchronous critical section: async contexts must not hold `NSLock`.
    private func takeFlushJob() -> FlushJob? {
        lock.lock()
        guard !pending.isEmpty else {
            flushScheduled = false
            lock.unlock()
            return nil
        }
        let batch = takeBatchLocked()
        writesSincePrune += batch.count
        let shouldPrune = writesSincePrune >= Self.pruneEveryWrites
        if shouldPrune { writesSincePrune = 0 }
        let job = FlushJob(
            batch: batch,
            ui: uiHandler,
            db: dbHandler,
            prune: shouldPrune ? pruneHandler : nil
        )
        lock.unlock()
        return job
    }

    private func appendDuplicateSummaryIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard suppressedDuplicates > 0 else { return }
        pending.append(makeDuplicateSummaryLocked())
        suppressedDuplicates = 0
    }

    private func takePendingBatch() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        if suppressedDuplicates > 0 {
            pending.append(makeDuplicateSummaryLocked())
            suppressedDuplicates = 0
        }
        return takeBatchLocked()
    }

    private func takeBatchLocked() -> [LogEntry] {
        var batch = pending
        pending.removeAll(keepingCapacity: true)
        if droppedEntries > 0 {
            batch.insert(
                LogEntry(level: .warning, source: "Logs", message: "日志缓冲已满，省略较早的 \(droppedEntries) 条日志"),
                at: 0
            )
            droppedEntries = 0
        }
        return batch
    }

    private func makeDuplicateSummaryLocked() -> LogEntry {
        LogEntry(
            level: duplicateLevel,
            source: duplicateSource,
            message: "（重复日志已省略 \(suppressedDuplicates) 条）"
        )
    }
}
