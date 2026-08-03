import Foundation

public enum ControlEventKind: String, Codable, Sendable {
    case launched
    case enabled
    case disabled
    case controlLost
    case controlRestored
    case stateWriteFailed
    case sleeping
    case woke
    case stopped
}

public struct ControlStateSnapshot: Codable, Equatable, Sendable {
    public let present: Bool
    public let valid: Bool
    public let enabled: Bool?
    public let percentage: Int?
    public let heartbeatAge: TimeInterval?

    public init(
        present: Bool,
        valid: Bool,
        enabled: Bool? = nil,
        percentage: Int? = nil,
        heartbeatAge: TimeInterval? = nil
    ) {
        self.present = present
        self.valid = valid
        self.enabled = enabled
        self.percentage = percentage
        self.heartbeatAge = heartbeatAge
    }
}

public struct ControlAcknowledgementSnapshot: Codable, Equatable, Sendable {
    public let present: Bool
    public let valid: Bool
    public let percentage: Int?
    public let heartbeatAge: TimeInterval?

    public init(
        present: Bool,
        valid: Bool,
        percentage: Int? = nil,
        heartbeatAge: TimeInterval? = nil
    ) {
        self.present = present
        self.valid = valid
        self.percentage = percentage
        self.heartbeatAge = heartbeatAge
    }
}

public struct ControlFanSnapshot: Codable, Equatable, Sendable {
    public let id: Int
    public let mode: String
    public let actualRPM: Double?
    public let targetRPM: Double?
    public let expectedRPM: Double?

    public init(id: Int, mode: String, actualRPM: Double?, targetRPM: Double?, expectedRPM: Double? = nil) {
        self.id = id
        self.mode = mode
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.expectedRPM = expectedRPM
    }
}

public struct ControlEvent: Codable, Equatable, Sendable {
    public let kind: ControlEventKind
    public let timestamp: TimeInterval
    public let message: String?
    public let expectedPercentage: Int?
    public let state: ControlStateSnapshot?
    public let acknowledgement: ControlAcknowledgementSnapshot?
    public let fans: [ControlFanSnapshot]?
    public let temperature: Double?
    public let pollDuration: TimeInterval?
    public let thermalState: String?

    public init(
        kind: ControlEventKind,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        message: String? = nil,
        expectedPercentage: Int? = nil,
        state: ControlStateSnapshot? = nil,
        acknowledgement: ControlAcknowledgementSnapshot? = nil,
        fans: [ControlFanSnapshot]? = nil,
        temperature: Double? = nil,
        pollDuration: TimeInterval? = nil,
        thermalState: String? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.message = message
        self.expectedPercentage = expectedPercentage
        self.state = state
        self.acknowledgement = acknowledgement
        self.fans = fans
        self.temperature = temperature
        self.pollDuration = pollDuration
        self.thermalState = thermalState
    }
}

public final class ControlEventRecorder: @unchecked Sendable {
    public static let defaultURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Fan Curve", isDirectory: true)
        .appendingPathComponent("control-events.jsonl")

    private let fileURL: URL
    private let maximumBytes: Int
    private let encoder = JSONEncoder()
    private let lock = NSLock()

    public init(fileURL: URL = ControlEventRecorder.defaultURL, maximumBytes: Int = 256 * 1_024) {
        self.fileURL = fileURL
        self.maximumBytes = max(1_024, maximumBytes)
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func record(_ event: ControlEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        do {
            try prepareDirectory()
            try rotateIfNeeded(for: line.count)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } catch {
            return
        }
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func rotateIfNeeded(for nextEntryBytes: Int) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let currentBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard currentBytes > 0, currentBytes + nextEntryBytes > maximumBytes else { return }
        let previousURL = URL(fileURLWithPath: fileURL.path + ".1")
        try? FileManager.default.removeItem(at: previousURL)
        try FileManager.default.moveItem(at: fileURL, to: previousURL)
    }
}
