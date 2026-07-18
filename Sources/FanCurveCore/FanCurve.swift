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
