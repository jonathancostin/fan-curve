import AppKit
import Darwin
import FanCurveCore
import Foundation
import StatsSMC

final class FanController: NSObject {
    static let shared = FanController()

    private static let cpuKeys = [
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
        "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
        "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"
    ]
    private static let pointsKey = "curvePoints"
    private static let historyKey = "temperatureHistory"

    private(set) var points: [CurvePoint]
    private(set) var averageTemperature: Double?
    private(set) var temperatureHistory: [TemperatureSample]
    private(set) var outputPercentage = 0
    private(set) var isEnabled = false
    private(set) var status = "Apple automatic control"
    var onUpdate: (() -> Void)?

    private let worker = DispatchQueue(label: "com.jonathan.FanCurve.smc")
    private let statePath = "/tmp/fancurve-\(getuid()).json"
    private let acknowledgementPath = "/var/run/fancurve-\(getuid()).ack"
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?

    private override init() {
        if let data = UserDefaults.standard.data(forKey: Self.pointsKey),
           let saved = try? JSONDecoder().decode([CurvePoint].self, from: data),
           saved.count == FanCurve.defaultPoints.count,
           FanCurve.isValid(saved) {
            points = saved
        } else {
            points = FanCurve.defaultPoints
        }
        temperatureHistory = UserDefaults.standard.data(forKey: Self.historyKey)
            .flatMap { try? JSONDecoder().decode([TemperatureSample].self, from: $0) } ?? []
        super.init()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.setEnabled(false, reason: "Paused for sleep") }
        poll()
    }

    func updatePoints(_ newPoints: [CurvePoint]) {
        let sorted = newPoints.sorted { $0.temperature < $1.temperature }
        guard sorted.count == FanCurve.defaultPoints.count, FanCurve.isValid(sorted) else { return }
        points = sorted
        if let data = try? JSONEncoder().encode(points) {
            UserDefaults.standard.set(data, forKey: Self.pointsKey)
        }
        refreshOutput()
        onUpdate?()
    }

    func setEnabled(_ enabled: Bool, reason: String? = nil) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            guard averageTemperature != nil else {
                isEnabled = false
                status = "No CPU temperature reading"
                onUpdate?()
                return
            }
            guard FileManager.default.isExecutableFile(atPath: installedHelperPath) else {
                isEnabled = false
                status = "Install the background helper first"
                onUpdate?()
                return
            }
            writeState(enabled: true)
            guard isEnabled else { onUpdate?(); return }
            status = "Waiting for background helper…"
        } else {
            writeState(enabled: false)
            status = reason ?? "Apple automatic control"
        }
        onUpdate?()
    }

    func shutdown() {
        timer?.invalidate()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if isEnabled {
            isEnabled = false
            writeState(enabled: false)
        }
    }

    private var installedHelperPath: String {
        "/Library/PrivilegedHelperTools/com.jonathan.FanCurveHelper"
    }

    private func poll() {
        let expectedPercentage = outputPercentage
        let acknowledgementPath = acknowledgementPath
        worker.async { [weak self] in
            let values = Self.cpuKeys.compactMap { SMC.shared.getValue($0) }.filter { (0...110).contains($0) }
            let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            let active = Self.controlIsActive(expectedPercentage: expectedPercentage, acknowledgementPath: acknowledgementPath)
            DispatchQueue.main.async {
                guard let self else { return }
                self.averageTemperature = average
                if let average { self.recordTemperature(average) }
                if average == nil, self.isEnabled {
                    self.setEnabled(false, reason: "No CPU temperature reading")
                } else {
                    if self.isEnabled {
                        self.status = active ? "Curve active" : "Waiting for background helper…"
                    }
                    self.refreshOutput()
                    self.onUpdate?()
                }
            }
        }
    }

    private func recordTemperature(_ temperature: Double) {
        let updated = TemperatureHistory.appending(temperature, at: Date().timeIntervalSince1970, to: temperatureHistory)
        guard updated != temperatureHistory else { return }
        temperatureHistory = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private static func controlIsActive(expectedPercentage: Int, acknowledgementPath: String) -> Bool {
        var info = stat()
        guard lstat(acknowledgementPath, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0,
              (info.st_mode & 0o022) == 0,
              let data = FileManager.default.contents(atPath: acknowledgementPath),
              let acknowledgement = try? JSONDecoder().decode(ControlAcknowledgement.self, from: data),
              acknowledgement.ownerUID == getuid(),
              acknowledgement.percentage == expectedPercentage,
              (0...2.5).contains(Date().timeIntervalSince1970 - acknowledgement.heartbeat),
              let rawCount = SMC.shared.getValue("FNum"), rawCount >= 1, rawCount <= 8 else { return false }

        return (0..<Int(rawCount)).allSatisfy { id in
            guard let minimum = SMC.shared.getValue("F\(id)Mn"),
                  let maximum = SMC.shared.getValue("F\(id)Mx"),
                  let target = SMC.shared.getValue("F\(id)Tg") else { return false }
            let expected = FanRange(id: id, minimumRPM: Int(minimum.rounded()), maximumRPM: Int(maximum.rounded()))
                .rpm(at: expectedPercentage)
            return SMC.shared.getValue(SMC.shared.fanModeKey(id)) == Double(FanMode.forced.rawValue)
                && abs(target - Double(expected)) <= 5
        }
    }

    private func refreshOutput() {
        guard let averageTemperature else {
            outputPercentage = 0
            return
        }
        let target = Int(FanCurve(points: points).percentage(at: averageTemperature).rounded())
        outputPercentage = isEnabled ? FanSmoothing.next(current: outputPercentage, target: target) : target
        if isEnabled { writeState(enabled: true) }
    }

    private func writeState(enabled: Bool) {
        let state = ControlState(
            enabled: enabled,
            percentage: outputPercentage,
            heartbeat: Date().timeIntervalSince1970,
            ownerUID: getuid()
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        let temporaryPath = statePath + ".new"
        do {
            try data.write(to: URL(fileURLWithPath: temporaryPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryPath)
            guard rename(temporaryPath, statePath) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            isEnabled = false
            status = "Could not update controller state"
        }
    }

}
