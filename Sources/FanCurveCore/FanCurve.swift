import Foundation

public struct CurvePoint: Codable, Equatable, Sendable {
    public var temperature: Double
    public var percentage: Double

    public init(temperature: Double, percentage: Double) {
        self.temperature = temperature
        self.percentage = percentage
    }
}

public struct FanCurve: Sendable {
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
        guard !points.isEmpty,
              points.allSatisfy({ temperatureRange.contains($0.temperature) && (0...100).contains($0.percentage) }) else {
            return false
        }
        return zip(points, points.dropFirst()).allSatisfy { left, right in
            right.temperature - left.temperature >= 2 && right.percentage >= left.percentage
        }
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
