import Foundation
import IOKit.ps

/// 本机电池的一次快照（只读、不持久化）。
///
/// Mac 台式机（Mac mini / Mac Studio）没有内部电池：`isPresent == false`，
/// UI 据此显示「未检测到电池」，而不是伪造 0%。
struct BatteryStatus: Equatable, Sendable {
    var isPresent: Bool
    var percentage: Int
    var isCharging: Bool
    var isFullyCharged: Bool
    /// 当前是否由电源适配器供电（与「是否正在充电」不同：电量已满或启用
    /// 优化充电时，适配器已接入但不充电）。
    var isOnExternalPower: Bool
    /// 系统估算的剩余/充满所需分钟数；系统正在估算或台式机时为 nil。
    var timeRemainingMinutes: Int?

    static let unavailable = BatteryStatus(
        isPresent: false,
        percentage: 0,
        isCharging: false,
        isFullyCharged: false,
        isOnExternalPower: true,
        timeRemainingMinutes: nil
    )

    /// 容量换算成 0–100 的整数百分比；`maxCapacity <= 0` 时返回 nil，避免除零。
    static func percentage(currentCapacity: Int, maxCapacity: Int) -> Int? {
        guard maxCapacity > 0 else { return nil }
        let ratio = Double(currentCapacity) / Double(maxCapacity)
        return min(100, max(0, Int((ratio * 100).rounded())))
    }
}

/// 通过 IOKit 读取内部电池。字典解析拆成纯函数，单元测试可以喂合成数据，
/// 不依赖测试机是否使用电池供电。
enum BatteryReader {
    // IOKit 的 key 宏在 Swift 中导入为 String，集中声明便于测试复用。
    static let currentCapacityKey = kIOPSCurrentCapacityKey
    static let maxCapacityKey = kIOPSMaxCapacityKey
    static let isPresentKey = kIOPSIsPresentKey
    static let isChargingKey = kIOPSIsChargingKey
    static let isChargedKey = kIOPSIsChargedKey
    static let powerSourceStateKey = kIOPSPowerSourceStateKey
    static let timeToEmptyKey = kIOPSTimeToEmptyKey
    static let timeToFullChargeKey = kIOPSTimeToFullChargeKey
    static let typeKey = kIOPSTypeKey
    static let internalBatteryType = kIOPSInternalBatteryType
    static let acPowerValue = kIOPSACPowerValue
    static let batteryPowerValue = kIOPSBatteryPowerValue

    /// 读取当前内部电池。没有电池或 IOKit 读取失败时返回 `.unavailable`。
    static func current() -> BatteryStatus {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return .unavailable
        }

        var fallback: BatteryStatus?
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                let status = parse(description: description)
            else { continue }
            // 多电源（如外接 UPS）时优先内部电池；其它电源只作为兜底。
            if (description[typeKey] as? String) == internalBatteryType {
                return status
            }
            if fallback == nil { fallback = status }
        }
        return fallback ?? .unavailable
    }

    /// 解析 `IOPSGetPowerSourceDescription` 的字典。缺少电量信息或电源不存在时返回 nil。
    static func parse(description: [String: Any]) -> BatteryStatus? {
        guard bool(description[isPresentKey]) == true,
              let current = int(description[currentCapacityKey]),
              let maxCapacity = int(description[maxCapacityKey]),
              let percentage = BatteryStatus.percentage(currentCapacity: current, maxCapacity: maxCapacity)
        else {
            return nil
        }

        let isFullyCharged = bool(description[isChargedKey]) ?? false
        let isCharging = bool(description[isChargingKey]) ?? false
        let isOnExternalPower = (description[powerSourceStateKey] as? String) == acPowerValue

        // 系统给 -1 / 0 表示「正在估算」。已充满时不再展示充满时间。
        let rawMinutes = isCharging && !isFullyCharged
            ? int(description[timeToFullChargeKey])
            : int(description[timeToEmptyKey])
        let minutes = rawMinutes.flatMap { $0 > 0 ? $0 : nil }

        return BatteryStatus(
            isPresent: true,
            percentage: percentage,
            isCharging: isCharging,
            isFullyCharged: isFullyCharged,
            isOnExternalPower: isOnExternalPower,
            timeRemainingMinutes: minutes
        )
    }

    // MARK: Tolerant value readers

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: return number.boolValue
        case let string as String:
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}
