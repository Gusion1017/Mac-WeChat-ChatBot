import Foundation

/// Timed outgoing-message scheduler.
///
/// - Event driven: one loop task computes the nearest `nextFireAt` and sleeps until
///   then (or until `update`/`stop` wakes it). No periodic polling.
/// - Fires due tasks exactly once, updates `lastFiredAt` / `nextFireAt`, and exposes
///   the new task list through `onChange` so the runtime can persist it.
/// - `normalize` rebuilds `nextFireAt` after a restart; `once` tasks in the past are
///   disabled instead of firing immediately.
actor SchedulerService {
    typealias FireHandler = @Sendable (ScheduledTask) async -> Void
    typealias ChangeHandler = @Sendable ([ScheduledTask]) -> Void

    var onFire: FireHandler?
    var onChange: ChangeHandler?

    private(set) var tasks: [ScheduledTask] = []
    private var running = false
    private var loopTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: Lifecycle

    func setHandlers(onFire: FireHandler?, onChange: ChangeHandler?) {
        self.onFire = onFire
        self.onChange = onChange
    }

    func start(tasks: [ScheduledTask]) {
        self.tasks = Self.normalize(tasks, now: Date(), calendar: calendar)
        running = true
        notifyChange()
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func update(tasks: [ScheduledTask]) {
        self.tasks = Self.normalize(tasks, now: Date(), calendar: calendar)
        notifyChange()
        wakeUp()
    }

    func stop() {
        running = false
        deadlineTask?.cancel()
        deadlineTask = nil
        if let waiter {
            self.waiter = nil
            waiter.resume()
        }
        loopTask?.cancel()
        loopTask = nil
    }

    func isRunning() -> Bool { running }

    // MARK: Loop

    private func runLoop() async {
        while running && !Task.isCancelled {
            let now = Date()
            let due = tasks.filter { $0.enabled && ($0.nextFireAt.map { $0 <= now } ?? false) }

            if !due.isEmpty {
                for dueTask in due {
                    guard running else { return }
                    guard var current = tasks.first(where: { $0.id == dueTask.id }), current.enabled else { continue }
                    current.lastFiredAt = now
                    if current.repeatRule == .once {
                        current.enabled = false
                        current.nextFireAt = nil
                    } else {
                        current.nextFireAt = Self.nextFireDate(for: current, after: now, calendar: calendar)
                        if current.nextFireAt == nil { current.enabled = false }
                    }
                    if let index = tasks.firstIndex(where: { $0.id == current.id }) {
                        tasks[index] = current
                    }
                    notifyChange()
                    await onFire?(current)
                }
                continue
            }

            let next = tasks
                .filter(\.enabled)
                .compactMap(\.nextFireAt)
                .min()
            if let next {
                let interval = next.timeIntervalSinceNow
                if interval <= 0 { continue }
                await waitForWake(after: interval)
            } else {
                await waitForWake(after: nil)
            }
        }
    }

    private func waitForWake(after interval: TimeInterval?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
            guard let interval, interval > 0 else { return }
            let nanoseconds = UInt64(min(interval, 86_400 * 365) * 1_000_000_000)
            deadlineTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await self?.wakeUp()
            }
        }
    }

    private func wakeUp() {
        deadlineTask?.cancel()
        deadlineTask = nil
        if let waiter {
            self.waiter = nil
            waiter.resume()
        }
    }

    private func notifyChange() {
        onChange?(tasks)
    }

    // MARK: Next-fire computation

    /// Recomputes `nextFireAt` for enabled tasks; disables expired `once` tasks.
    static func normalize(_ tasks: [ScheduledTask], now: Date = Date(), calendar: Calendar = .current) -> [ScheduledTask] {
        tasks.map { task in
            var copy = task
            if !copy.enabled {
                copy.nextFireAt = nil
                return copy
            }
            guard copy.repeatRule != .once || copy.fireAt > now else {
                copy.enabled = false
                copy.nextFireAt = nil
                return copy
            }
            copy.nextFireAt = nextFireDate(for: copy, after: now, calendar: calendar)
            if copy.nextFireAt == nil && copy.repeatRule == .once {
                copy.enabled = false
            }
            return copy
        }
    }

    /// Next occurrence strictly after `after`, or `nil` when the task should not fire again.
    static func nextFireDate(for task: ScheduledTask, after: Date, calendar: Calendar = .current) -> Date? {
        switch task.repeatRule {
        case .once:
            return task.fireAt > after ? task.fireAt : nil
        case .daily:
            return nextTimeOfDay(task.fireAt, after: after, allowedWeekdays: nil, calendar: calendar)
        case .weekdays:
            return nextTimeOfDay(task.fireAt, after: after, allowedWeekdays: [2, 3, 4, 5, 6], calendar: calendar)
        case .weekly:
            let days = Set(task.weekdays.filter { (1...7).contains($0) })
            return nextTimeOfDay(task.fireAt, after: after, allowedWeekdays: days.isEmpty ? nil : days, calendar: calendar)
        }
    }

    private static func nextTimeOfDay(
        _ source: Date,
        after: Date,
        allowedWeekdays: Set<Int>?,
        calendar: Calendar
    ) -> Date? {
        let components = calendar.dateComponents([.hour, .minute, .second], from: source)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let startOfToday = calendar.startOfDay(for: after)

        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: second, of: day) else { continue }
            guard candidate > after else { continue }
            if let allowedWeekdays {
                let weekday = calendar.component(.weekday, from: candidate)
                guard allowedWeekdays.contains(weekday) else { continue }
            }
            return candidate
        }
        return nil
    }
}
