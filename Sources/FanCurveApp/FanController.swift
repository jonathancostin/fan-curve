import AppKit
import Darwin
import FanCurveCore
import Foundation
import StatsSMC
import UserNotifications

final class FanController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FanController()

    private static let pointsKey = "curvePoints"
    private static let historyKey = "temperatureHistory"
    private static let confirmedUnverifiedModelKey = "confirmedUnverifiedModel"
    static let resumeAfterLaunchKey = "resumeAfterLaunch"

    private(set) var points: [CurvePoint]
    private(set) var averageTemperature: Double?
    private(set) var temperatureHistory: [TemperatureSample]
    private(set) var outputPercentage = 0
    private(set) var detectedFanCount = 0
    private(set) var supportLevel = DeviceSupportLevel.unsupported
    private(set) var fanTelemetry: [FanTelemetry] = []
    private(set) var isEnabled = false
    private(set) var controlIsActive = false
    private(set) var isBusy = false
    private(set) var helperInstalled = HelperInstallation.isSecure()
    private(set) var resumeAfterLaunch: Bool
    private(set) var status = "Apple automatic control"
    var onUpdate: (() -> Void)?

    private let worker = DispatchQueue(label: "com.jonathan.FanCurve.smc")
    private let deviceModel = MacHardware.modelIdentifier()
    private let statePath = "/tmp/fancurve-\(getuid()).json"
    private let acknowledgementPath = "/var/run/fancurve-\(getuid()).ack"
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var wakeRecovery = WakeRecovery()
    private var controlConfirmation = ControlConfirmationDeadline()
    private var launchRecovery: LaunchRecovery
    private var activeControlTransition = ActiveControlTransition()
    private var availableSMCKeys: Set<String>?
    private var fanRanges: [FanRange]?

    private override init() {
        resumeAfterLaunch = UserDefaults.standard.bool(forKey: Self.resumeAfterLaunchKey)
        launchRecovery = LaunchRecovery(requested: resumeAfterLaunch)
        if let data = UserDefaults.standard.data(forKey: Self.pointsKey),
           let saved = FanCurve.decodePoints(from: data) {
            points = saved
        } else {
            points = FanCurve.defaultPoints
        }
        temperatureHistory = UserDefaults.standard.data(forKey: Self.historyKey)
            .flatMap { try? JSONDecoder().decode([TemperatureSample].self, from: $0) } ?? []
        super.init()
        UNUserNotificationCenter.current().delegate = self

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        let notifications = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(notifications.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.prepareForSleep() })
        workspaceObservers.append(notifications.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.didWake() })
        poll()
    }

    func updatePoints(_ newPoints: [CurvePoint]) {
        let sorted = newPoints.sorted { $0.temperature < $1.temperature }
        guard FanCurve.isValid(sorted) else { return }
        points = sorted
        if let data = try? JSONEncoder().encode(points) {
            UserDefaults.standard.set(data, forKey: Self.pointsKey)
        }
        refreshOutput()
        onUpdate?()
    }

    func resetPoints() {
        updatePoints(FanCurve.defaultPoints)
        status = "Default curve restored"
        onUpdate?()
    }

    func copyCurve() {
        guard let data = try? JSONEncoder().encode(points),
              let json = String(data: data, encoding: .utf8) else {
            return showStatus("Could not copy curve")
        }
        NSPasteboard.general.clearContents()
        showStatus(
            NSPasteboard.general.setString(json, forType: .string)
                ? "Curve copied"
                : "Could not copy curve"
        )
    }

    func pasteCurve() {
        guard let json = NSPasteboard.general.string(forType: .string),
              let data = json.data(using: .utf8),
              let pasted = FanCurve.decodePoints(from: data) else {
            return showStatus("Paste failed: invalid curve")
        }
        updatePoints(pasted)
        showStatus("Curve pasted")
    }

    func showStatus(_ message: String) {
        status = message
        onUpdate?()
    }

    func setEnabled(_ enabled: Bool, reason: String? = nil) {
        if !enabled {
            wakeRecovery.cancelResume()
            controlConfirmation.stop()
            launchRecovery.cancelResume()
        }
        guard !isBusy else { return }
        guard enabled != isEnabled else { return }
        guard !enabled || !needsSupportConfirmation else {
            status = "Confirm this unverified Mac before enabling"
            onUpdate?()
            return
        }
        isEnabled = enabled
        if !enabled {
            _ = activeControlTransition.shouldNotify(isEnabled: false, isActive: false)
        }
        if enabled {
            guard averageTemperature != nil else {
                isEnabled = false
                status = "No CPU temperature reading"
                onUpdate?()
                return
            }
            guard detectedFanCount > 0 else {
                isEnabled = false
                status = "No supported fans found"
                onUpdate?()
                return
            }
            guard HelperInstallation.isSecure() else {
                isEnabled = false
                status = "Install the background helper first"
                onUpdate?()
                return
            }
            guard !helperNeedsUpdate else {
                isEnabled = false
                status = "Update the background helper first"
                onUpdate?()
                return
            }
            writeState(enabled: true)
            guard isEnabled else { onUpdate?(); return }
            controlConfirmation.start(at: ProcessInfo.processInfo.systemUptime)
            status = "Waiting for background helper…"
        } else {
            controlIsActive = false
            writeState(enabled: false)
            status = reason ?? "Apple automatic control"
        }
        onUpdate?()
    }

    var needsSupportConfirmation: Bool {
        supportLevel == .knownKeys
            && UserDefaults.standard.string(forKey: Self.confirmedUnverifiedModelKey) != deviceModel
    }

    func confirmUnverifiedDevice() {
        UserDefaults.standard.set(deviceModel, forKey: Self.confirmedUnverifiedModelKey)
    }

    func setResumeAfterLaunch(_ enabled: Bool) {
        resumeAfterLaunch = enabled
        UserDefaults.standard.set(enabled, forKey: Self.resumeAfterLaunchKey)
        if !enabled { launchRecovery.cancelResume() }
        status = enabled ? "Resume after launch enabled" : "Resume after launch disabled"
        onUpdate?()
    }

    var canInstallHelper: Bool {
        bundledResource("install-helper.sh") != nil && !isBusy
    }

    var helperNeedsUpdate: Bool {
        guard helperInstalled, let bundledHelper = bundledResource("FanCurveHelper") else { return false }
        return HelperInstallation.requiresUpdate(
            bundledSHA256: HelperInstallation.sha256(bundledHelper.path),
            installedSHA256: HelperInstallation.sha256(HelperInstallation.helperPath)
        )
    }

    var canCopySupportReport: Bool {
        bundledResource("FanCurveProbe") != nil && !isBusy
    }

    func installHelper() {
        guard let installer = bundledResource("install-helper.sh"), !isBusy else { return }
        if isEnabled { setEnabled(false, reason: "Preparing helper install…") }
        isBusy = true
        status = helperNeedsUpdate
            ? "Updating background helper…"
            : helperInstalled ? "Repairing background helper…" : "Installing background helper…"
        onUpdate?()

        worker.async { [weak self] in
            guard let self else { return }
            for _ in 0..<20 where FileManager.default.fileExists(atPath: "/var/run/fancurve.active") {
                usleep(250_000)
            }
            guard !FileManager.default.fileExists(atPath: "/var/run/fancurve.active") else {
                return self.finishTask(status: "Apple control was not confirmed; helper unchanged")
            }

            let result = Self.run(installer, arguments: ["install"])
            let installed = HelperInstallation.isSecure()
            let status = result?.status == 0 && installed
                ? "Background helper installed"
                : result?.message ?? "Background helper install failed"
            self.finishTask(status: status, helperInstalled: installed)
        }
    }

    func copySupportReport() {
        guard let probe = bundledResource("FanCurveProbe"), !isBusy else { return }
        isBusy = true
        status = "Collecting support report…"
        onUpdate?()

        worker.async { [weak self] in
            guard let self else { return }
            guard let result = Self.run(probe),
                  result.status == 0,
                  let data = result.output,
                  (try? JSONSerialization.jsonObject(with: data)) != nil,
                  let report = String(data: data, encoding: .utf8) else {
                return self.finishTask(status: "Could not collect support report")
            }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                self.isBusy = false
                self.status = "Support report copied"
                self.poll()
                self.onUpdate?()
            }
        }
    }

    func shutdown() {
        timer?.invalidate()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if isEnabled {
            isEnabled = false
            controlConfirmation.stop()
            writeState(enabled: false)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func bundledResource(_ name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    private static func run(_ executable: URL, arguments: [String] = []) -> (
        status: Int32,
        output: Data?,
        message: String?
    )? {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            let messageData = errorData.isEmpty ? data : errorData
            let message = String(data: messageData, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init)
            return (process.terminationStatus, data, message)
        } catch {
            return nil
        }
    }

    private func finishTask(status: String, helperInstalled: Bool? = nil) {
        DispatchQueue.main.async {
            if let helperInstalled { self.helperInstalled = helperInstalled }
            self.isBusy = false
            self.status = status
            self.poll()
            self.onUpdate?()
        }
    }

    private func poll() {
        guard !isBusy else { return }
        guard let isWakePoll = wakeRecovery.beginPoll() else { return }
        let expectedPercentage = outputPercentage
        let acknowledgementPath = acknowledgementPath
        let bundledHelperPath = launchRecovery.isPending
            ? bundledResource("FanCurveHelper")?.path
            : nil
        worker.async { [weak self] in
            guard let self else { return }
            let availableKeys = self.availableSMCKeys ?? Set(SMC.shared.getAllKeys())
            if !availableKeys.isEmpty { self.availableSMCKeys = availableKeys }
            let discoveredFans = self.fanRanges ?? MacHardware.fanRanges { SMC.shared.getValue($0) }
            let fanTelemetry = discoveredFans.map { fan in
                FanTelemetry(
                    id: fan.id,
                    actualRPM: SMC.shared.getValue("F\(fan.id)Ac"),
                    targetRPM: SMC.shared.getValue("F\(fan.id)Tg"),
                    mode: Self.fanMode(fan.id)
                )
            }
            let fanControlSupported = MacHardware.supportsFanControl(
                discoveredFans,
                readMode: { id in fanTelemetry.first { $0.id == id }?.mode }
            )
            let supportLevel = MacHardware.supportLevel(
                model: self.deviceModel,
                fanCount: discoveredFans.count,
                fanControlSupported: fanControlSupported
            )
            let fans = supportLevel == .unsupported ? [] : discoveredFans
            if !fans.isEmpty { self.fanRanges = fans }
            let average = MacHardware.averageCPUTemperature(availableKeys: availableKeys) {
                SMC.shared.getValue($0)
            }
            let active = Self.controlIsActive(
                expectedPercentage: expectedPercentage,
                acknowledgementPath: acknowledgementPath,
                fans: fans,
                fanTelemetry: fanTelemetry
            )
            let helperInstalled = HelperInstallation.isSecure()
            let helperIsCurrent = bundledHelperPath.map {
                HelperInstallation.isCurrent(bundledHelperPath: $0)
            } ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let shouldResume = self.wakeRecovery.finishPoll(
                    isWakePoll: isWakePoll,
                    hasTemperature: average != nil
                )
                let launchResumeWasPending = self.launchRecovery.isPending
                let shouldResumeAfterLaunch = self.launchRecovery.finishFirstPoll(
                    hasTemperature: average != nil,
                    hasSupportedFans: !fans.isEmpty,
                    helperIsCurrent: helperIsCurrent
                )
                self.averageTemperature = average
                self.detectedFanCount = fans.count
                self.supportLevel = supportLevel
                self.fanTelemetry = fanTelemetry
                self.controlIsActive = active
                self.helperInstalled = helperInstalled
                if launchResumeWasPending && !shouldResumeAfterLaunch {
                    self.status = "Launch resume skipped; check temperature, fans, and helper"
                }
                if shouldResume || shouldResumeAfterLaunch { self.setEnabled(true) }
                if active {
                    _ = self.activeControlTransition.shouldNotify(
                        isEnabled: self.isEnabled,
                        isActive: true
                    )
                }
                if average == nil, self.isEnabled {
                    if self.activeControlTransition.shouldNotify(isEnabled: true, isActive: false) {
                        self.notifyControlFailure("No CPU temperature reading")
                    }
                    self.setEnabled(false, reason: "No CPU temperature reading")
                } else {
                    if self.isEnabled {
                        switch self.controlConfirmation.failure(
                            isConfirmed: active,
                            at: ProcessInfo.processInfo.systemUptime
                        ) {
                        case .neverConfirmed:
                            self.setEnabled(false, reason: "Background helper did not confirm control")
                        case .lost:
                            if self.activeControlTransition.shouldNotify(isEnabled: true, isActive: false) {
                                self.notifyControlFailure("Background helper stopped confirming fan control")
                            }
                            self.setEnabled(false, reason: "Background helper stopped confirming control")
                        case nil:
                            self.status = active ? "Curve active" : "Waiting for background helper…"
                        }
                    }
                    self.refreshOutput()
                    if let average {
                        self.recordTemperature(average, fanPercentage: self.outputPercentage)
                    }
                    self.onUpdate?()
                }
            }
        }
    }

    private func prepareForSleep() {
        launchRecovery.cancelResume()
        wakeRecovery.prepareForSleep(wasEnabled: isEnabled)
        guard isEnabled else { return }
        isEnabled = false
        controlConfirmation.stop()
        _ = activeControlTransition.shouldNotify(isEnabled: false, isActive: false)
        writeState(enabled: false)
        status = "Paused for sleep"
        onUpdate?()
    }

    private func didWake() {
        guard wakeRecovery.didWake() else { return }
        status = "Waiting for temperature after wake…"
        poll()
        onUpdate?()
    }

    private func recordTemperature(_ temperature: Double, fanPercentage: Int) {
        let updated = TemperatureHistory.appending(
            temperature,
            fanPercentage: fanPercentage,
            at: Date().timeIntervalSince1970,
            to: temperatureHistory
        )
        guard updated != temperatureHistory else { return }
        temperatureHistory = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private func notifyControlFailure(_ reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Fan Curve lost active control"
        content.body = "\(reason). Apple automatic control should take over."
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }
    }

    private static func controlIsActive(
        expectedPercentage: Int,
        acknowledgementPath: String,
        fans: [FanRange],
        fanTelemetry: [FanTelemetry]
    ) -> Bool {
        var info = stat()
        guard lstat(acknowledgementPath, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0,
              (info.st_mode & 0o022) == 0,
              let data = FileManager.default.contents(atPath: acknowledgementPath),
              let acknowledgement = try? JSONDecoder().decode(ControlAcknowledgement.self, from: data),
              ControlPolicy.acknowledgementMatches(
                  acknowledgement,
                  expectedPercentage: expectedPercentage,
                  ownerUID: getuid(),
                  now: Date().timeIntervalSince1970
              ) else { return false }

        guard !fans.isEmpty else { return false }
        return fans.allSatisfy { fan in
            guard let telemetry = fanTelemetry.first(where: { $0.id == fan.id }),
                  let target = telemetry.targetRPM else { return false }
            return telemetry.mode == .forced
                && abs(target - Double(fan.rpm(at: expectedPercentage))) <= 5
        }
    }

    private static func fanMode(_ id: Int) -> HardwareFanMode? {
        #if arch(arm64)
        return MacHardware.appleFanMode(SMC.shared.getValue(SMC.shared.fanModeKey(id)))
        #else
        return MacHardware.intelFanMode(SMC.shared.getValue("FS! "), fanID: id)
        #endif
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
