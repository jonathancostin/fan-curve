import Darwin
import Foundation

public struct CurvePoint: Codable, Equatable, Sendable {
    public var temperature: Double
    public var percentage: Double

    public init(temperature: Double, percentage: Double) {
        self.temperature = temperature
        self.percentage = percentage
    }
}

public struct TemperatureSample: Codable, Equatable, Sendable {
    public let timestamp: TimeInterval
    public let temperature: Double

    public init(timestamp: TimeInterval, temperature: Double) {
        self.timestamp = timestamp
        self.temperature = temperature
    }
}

public enum TemperatureHistory {
    public static func appending(
        _ temperature: Double,
        at timestamp: TimeInterval,
        to samples: [TemperatureSample],
        interval: TimeInterval = 60,
        retention: TimeInterval = 24 * 60 * 60
    ) -> [TemperatureSample] {
        let retained = samples.filter { timestamp - $0.timestamp < retention && $0.timestamp <= timestamp }
        guard retained.last.map({ timestamp - $0.timestamp >= interval }) ?? true else { return retained }
        return retained + [TemperatureSample(timestamp: timestamp, temperature: temperature)]
    }
}

public struct FanCurve: Sendable {
    public static let minimumPointCount = 2
    public static let temperatureRange = 30.0...100.0
    public static let defaultPoints = [
        CurvePoint(temperature: 35, percentage: 0),
        CurvePoint(temperature: 50, percentage: 20),
        CurvePoint(temperature: 65, percentage: 45),
        CurvePoint(temperature: 80, percentage: 75),
        CurvePoint(temperature: 95, percentage: 100)
    ]

    public var points: [CurvePoint]

    public static func isValid(_ points: [CurvePoint]) -> Bool {
        guard points.count >= minimumPointCount,
              points.allSatisfy({ temperatureRange.contains($0.temperature) && (0...100).contains($0.percentage) }) else {
            return false
        }
        return zip(points, points.dropFirst()).allSatisfy { left, right in
            right.temperature - left.temperature >= 2 && right.percentage >= left.percentage
        }
    }

    public static func addingPoint(to points: [CurvePoint]) -> [CurvePoint]? {
        guard isValid(points),
              let index = zip(points.indices, zip(points, points.dropFirst())).max(by: {
                  $0.1.1.temperature - $0.1.0.temperature < $1.1.1.temperature - $1.1.0.temperature
              })?.0 else { return nil }
        let left = points[index]
        let right = points[index + 1]
        guard right.temperature - left.temperature >= 4 else { return nil }
        var updated = points
        updated.insert(CurvePoint(
            temperature: (left.temperature + right.temperature) / 2,
            percentage: ((left.percentage + right.percentage) / 2).rounded()
        ), at: index + 1)
        return updated
    }

    public static func deletingPoint(at index: Int, from points: [CurvePoint]) -> [CurvePoint]? {
        guard isValid(points), points.count > minimumPointCount, points.indices.contains(index) else { return nil }
        var updated = points
        updated.remove(at: index)
        return updated
    }

    public init(points: [CurvePoint]) {
        self.points = points.sorted { $0.temperature < $1.temperature }
    }

    public func percentage(at temperature: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if temperature <= first.temperature { return first.percentage }
        if temperature >= last.temperature { return last.percentage }

        for (left, right) in zip(points, points.dropFirst()) where temperature <= right.temperature {
            let progress = (temperature - left.temperature) / (right.temperature - left.temperature)
            return left.percentage + progress * (right.percentage - left.percentage)
        }
        return last.percentage
    }
}

public struct ControlState: Codable, Sendable {
    public let enabled: Bool
    public let percentage: Int
    public let heartbeat: TimeInterval
    public let ownerUID: UInt32

    public init(enabled: Bool, percentage: Int, heartbeat: TimeInterval, ownerUID: UInt32) {
        self.enabled = enabled
        self.percentage = percentage
        self.heartbeat = heartbeat
        self.ownerUID = ownerUID
    }
}

public struct ControlAcknowledgement: Codable, Sendable {
    public let heartbeat: TimeInterval
    public let percentage: Int
    public let ownerUID: UInt32

    public init(heartbeat: TimeInterval, percentage: Int, ownerUID: UInt32) {
        self.heartbeat = heartbeat
        self.percentage = percentage
        self.ownerUID = ownerUID
    }
}

public enum ControlPolicy {
    public static func allowsControl(
        state: ControlState?,
        now: TimeInterval,
        heartbeatTimeout: TimeInterval = 5,
        thermalPressureIsSafe: Bool
    ) -> Bool {
        guard let state,
              state.enabled,
              (0...100).contains(state.percentage),
              state.heartbeat.isFinite,
              now.isFinite,
              heartbeatTimeout.isFinite,
              heartbeatTimeout > 0,
              (0...heartbeatTimeout).contains(now - state.heartbeat),
              thermalPressureIsSafe else { return false }
        return true
    }

    public static func acknowledgementMatches(
        _ acknowledgement: ControlAcknowledgement,
        expectedPercentage: Int,
        ownerUID: UInt32,
        now: TimeInterval,
        heartbeatTimeout: TimeInterval = 2.5
    ) -> Bool {
        acknowledgement.ownerUID == ownerUID
            && acknowledgement.percentage == expectedPercentage
            && acknowledgement.heartbeat.isFinite
            && now.isFinite
            && heartbeatTimeout.isFinite
            && heartbeatTimeout > 0
            && (0...heartbeatTimeout).contains(now - acknowledgement.heartbeat)
    }
}

public enum HelperInstallation {
    public static let helperPath = "/Library/PrivilegedHelperTools/com.jonathan.FanCurveHelper"
    public static let launchDaemonPath = "/Library/LaunchDaemons/com.jonathan.FanCurveHelper.plist"

    public static func isSecure(
        helperPath: String = HelperInstallation.helperPath,
        launchDaemonPath: String = HelperInstallation.launchDaemonPath
    ) -> Bool {
        secureRegularFile(helperPath, mustBeExecutable: true)
            && secureRegularFile(launchDaemonPath, mustBeExecutable: false)
    }

    private static func secureRegularFile(_ path: String, mustBeExecutable: Bool) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == 0
            && (info.st_mode & 0o022) == 0
            && (!mustBeExecutable || (info.st_mode & 0o111) != 0)
    }
}

public struct FanRange: Equatable, Sendable {
    public let id: Int
    public let minimumRPM: Int
    public let maximumRPM: Int

    public init(id: Int, minimumRPM: Int, maximumRPM: Int) {
        self.id = id
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
    }

    public func rpm(at percentage: Int) -> Int {
        minimumRPM + ((maximumRPM - minimumRPM) * min(100, max(0, percentage)) / 100)
    }
}

public enum FanSmoothing {
    public static func next(
        current: Int,
        target: Int,
        riseLimit: Int = 5,
        fallLimit: Int = 2,
        deadband: Int = 2
    ) -> Int {
        let difference = target - current
        guard abs(difference) > deadband else { return current }
        return current + min(riseLimit, max(-fallLimit, difference))
    }
}

public struct CPUTemperatureSnapshot: Equatable, Sendable {
    public let average: Double
    public let sensorKeys: [String]

    public init(average: Double, sensorKeys: [String]) {
        self.average = average
        self.sensorKeys = sensorKeys
    }
}

public enum HardwareFanMode: String, Codable, Sendable {
    case automatic
    case forced
    case system

    public var isAutomatic: Bool {
        self != .forced
    }
}

public enum MacHardware {
    private static let intelCoreKeys = (0...9).flatMap { ["TC\($0)c", "TC\($0)C"] }
    private static let intelFallbackKeys = ["TCAD", "TC0D", "TC0E", "TC0F", "TC0H", "TC0P"]

    private static let appleSiliconCPUKeys = [
        "Te05", "Te09", "Te0H", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
        "Tp00", "Tp01", "Tp04", "Tp05", "Tp08", "Tp09",
        "Tp0C", "Tp0D", "Tp0G", "Tp0H", "Tp0K", "Tp0L",
        "Tp0O", "Tp0P", "Tp0R", "Tp0T", "Tp0U", "Tp0V",
        "Tp0X", "Tp0Y", "Tp0a", "Tp0b", "Tp0d", "Tp0e",
        "Tp0f", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u",
        "Tp0y", "Tp1h", "Tp1l", "Tp1p", "Tp1t"
    ]

    public static func averageCPUTemperature(
        availableKeys: Set<String>,
        read: (String) -> Double?
    ) -> Double? {
        cpuTemperatureSnapshot(availableKeys: availableKeys, read: read)?.average
    }

    public static func cpuTemperatureSnapshot(
        availableKeys: Set<String>,
        read: (String) -> Double?
    ) -> CPUTemperatureSnapshot? {
        #if arch(arm64)
        cpuTemperatureSnapshot(availableKeys: availableKeys, appleSilicon: true, read: read)
        #else
        cpuTemperatureSnapshot(availableKeys: availableKeys, appleSilicon: false, read: read)
        #endif
    }

    public static func fanRanges(read: (String) -> Double?) -> [FanRange] {
        guard let rawCount = read("FNum"),
              rawCount.isFinite,
              rawCount.rounded() == rawCount,
              (1.0...8.0).contains(rawCount) else { return [] }

        let count = Int(rawCount)
        let fans = (0..<count).compactMap { id -> FanRange? in
            guard let rawMinimum = read("F\(id)Mn"),
                  let rawMaximum = read("F\(id)Mx"),
                  rawMinimum.isFinite,
                  rawMaximum.isFinite,
                  rawMinimum >= 0,
                  rawMaximum > rawMinimum,
                  rawMaximum <= 20_000 else { return nil }
            let minimum = Int(rawMinimum.rounded())
            let maximum = Int(rawMaximum.rounded())
            guard maximum > minimum else { return nil }
            return FanRange(id: id, minimumRPM: minimum, maximumRPM: maximum)
        }
        return fans.count == count ? fans : []
    }

    public static func supportsFanControl(
        _ fans: [FanRange],
        readMode: (Int) -> HardwareFanMode?
    ) -> Bool {
        guard !fans.isEmpty else { return false }
        #if arch(arm64)
        return fans.allSatisfy { readMode($0.id) != nil }
        #else
        return fans.count <= 2 && fans.allSatisfy { readMode($0.id) != nil }
        #endif
    }

    public static func appleFanMode(_ rawMode: Double?) -> HardwareFanMode? {
        guard let rawMode,
              rawMode.isFinite,
              rawMode.rounded() == rawMode,
              (0.0...3.0).contains(rawMode) else { return nil }
        switch Int(rawMode) {
        case 0: return .automatic
        case 1: return .forced
        case 3: return .system
        default: return nil
        }
    }

    public static func intelFanMode(_ rawMask: Double?, fanID: Int) -> HardwareFanMode? {
        guard let rawMask,
              rawMask.isFinite,
              rawMask.rounded() == rawMask,
              (0.0...3.0).contains(rawMask),
              (0...1).contains(fanID) else { return nil }
        return Int(rawMask) & (1 << fanID) == 0 ? .automatic : .forced
    }

    static func cpuTemperatureSnapshot(
        availableKeys: Set<String>,
        appleSilicon: Bool,
        read: (String) -> Double?
    ) -> CPUTemperatureSnapshot? {
        let candidates = appleSilicon ? appleSiliconCPUKeys : intelCoreKeys
        let readings = candidates.compactMap { key -> (String, Double)? in
            guard availableKeys.contains(key),
                  let value = read(key),
                  value.isFinite,
                  (0...110).contains(value) else { return nil }
            return (key, value)
        }
        if !readings.isEmpty {
            return CPUTemperatureSnapshot(
                average: readings.map(\.1).reduce(0, +) / Double(readings.count),
                sensorKeys: readings.map(\.0)
            )
        }
        guard !appleSilicon else { return nil }
        for key in intelFallbackKeys where availableKeys.contains(key) {
            guard let value = read(key), value.isFinite, (0...110).contains(value) else { continue }
            return CPUTemperatureSnapshot(average: value, sensorKeys: [key])
        }
        return nil
    }
}

public struct WakeRecovery {
    private var pollInFlight = false
    private var resumeAfterWake = false
    private var needsFreshWakePoll = false

    public init() {}

    public mutating func beginPoll() -> Bool? {
        guard !pollInFlight else { return nil }
        pollInFlight = true
        let isWakePoll = needsFreshWakePoll
        needsFreshWakePoll = false
        return isWakePoll
    }

    public mutating func finishPoll(isWakePoll: Bool, hasTemperature: Bool) -> Bool {
        pollInFlight = false
        guard isWakePoll, resumeAfterWake else { return false }
        guard hasTemperature else {
            needsFreshWakePoll = true
            return false
        }
        resumeAfterWake = false
        return true
    }

    public mutating func prepareForSleep(wasEnabled: Bool) {
        resumeAfterWake = wasEnabled
        needsFreshWakePoll = false
    }

    public mutating func didWake() -> Bool {
        needsFreshWakePoll = resumeAfterWake
        return resumeAfterWake
    }

    public mutating func cancelResume() {
        resumeAfterWake = false
        needsFreshWakePoll = false
    }
}
