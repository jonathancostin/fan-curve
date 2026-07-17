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

    private(set) var points: [CurvePoint]
    private(set) var averageTemperature: Double?
    private(set) var outputPercentage = 0
    private(set) var isEnabled = false
    private(set) var status = "Apple automatic control"
    var onUpdate: (() -> Void)?

    private let worker = DispatchQueue(label: "com.jonathan.FanCurve.smc")
    private let statePath = "/tmp/fancurve-\(getuid()).json"
    private var helperProcess: Process?
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
            guard FileManager.default.isExecutableFile(atPath: helperPath) else {
                isEnabled = false
                status = "Helper missing — rebuild the app"
                onUpdate?()
                return
            }
            writeState(enabled: true)
            guard isEnabled else { onUpdate?(); return }
            startHelper()
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

    private var helperPath: String {
        Bundle.main.bundlePath + "/Contents/Resources/FanCurveHelper"
    }

    private func poll() {
        worker.async { [weak self] in
            let values = Self.cpuKeys.compactMap { SMC.shared.getValue($0) }.filter { (0...110).contains($0) }
            let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            let forced = SMC.shared.getValue(SMC.shared.fanModeKey(0)) == Double(FanMode.forced.rawValue)
            DispatchQueue.main.async {
                guard let self else { return }
                self.averageTemperature = average
                if average == nil, self.isEnabled {
                    self.setEnabled(false, reason: "No CPU temperature reading")
                } else {
                    if self.isEnabled, forced { self.status = "Curve active" }
                    self.refreshOutput()
                    self.onUpdate?()
                }
            }
        }
    }

    private func refreshOutput() {
        guard let averageTemperature else {
            outputPercentage = 0
            return
        }
        outputPercentage = Int(FanCurve(points: points).percentage(at: averageTemperature).rounded())
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

    private func startHelper() {
        guard helperProcess == nil || helperProcess?.isRunning == false else { return }
        let escapedHelper = helperPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedState = statePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let command = "quoted form of \"\(escapedHelper)\" & \" \" & quoted form of \"\(escapedState)\" & \" \(getuid())\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script (\(command)) with administrator privileges"]
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.helperProcess = nil
                if self.isEnabled {
                    self.isEnabled = false
                    self.writeState(enabled: false)
                    self.status = process.terminationStatus == 0 ? "Controller stopped" : "Administrator approval canceled"
                    self.onUpdate?()
                }
            }
        }
        do {
            try process.run()
            helperProcess = process
            status = "Waiting for administrator approval…"
        } catch {
            isEnabled = false
            status = "Could not start controller"
        }
    }
}
