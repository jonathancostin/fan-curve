import AppKit
import Darwin
import FanCurveCore
import Foundation
import IOKit.ps
import StatsSMC
import UserNotifications

final class FanController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FanController()

    private static let pointsKey = "curvePoints"
    private static let selectedProfileKey = "selectedCurveProfile"
    private static let historyKey = "temperatureHistory"
    private static let confirmedUnverifiedModelKey = "confirmedUnverifiedModel"
    private static let sceneBudgetsKey = "sceneBudgets"
    private static let automaticScenesKey = "automaticScenes"
    static let resumeAfterLaunchKey = "resumeAfterLaunch"

    static let sceneNames = FanSceneCatalog.names


    private(set) var points: [CurvePoint]
    private(set) var selectedProfile: Int
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
    private(set) var sceneBudgets: [FanBudget]
    private(set) var automaticScenes: Bool
    private(set) var powerSource = ScenePowerSource.unknown
    private(set) var budgetCapped = false
    private(set) var status = "Apple automatic control"
    var onUpdate: (() -> Void)?

    private let worker = DispatchQueue(label: "com.jonathan.FanCurve.smc")
    private let controlRecorder = ControlEventRecorder()
    private let deviceModel = MacHardware.modelIdentifier()
    private let statePath = "/tmp/fancurve-\(getuid()).json"
    private let acknowledgementPath = "/var/run/fancurve-\(getuid()).ack"
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var wakeRecovery = WakeRecovery()
    private var controlConfirmation = ControlConfirmationDeadline()
    private var controlLoopSchedule = ControlLoopSchedule()
    private var lastTemperatureReadingAt: TimeInterval?
    private var launchRecovery: LaunchRecovery
    private var activeControlTransition = ActiveControlTransition()
    private var availableSMCKeys: Set<String>?
    private var fanRanges: [FanRange]?
    private override init() {
        resumeAfterLaunch = UserDefaults.standard.bool(forKey: Self.resumeAfterLaunchKey)
        automaticScenes = UserDefaults.standard.bool(forKey: Self.automaticScenesKey)
        sceneBudgets = Self.loadSceneBudgets()
        launchRecovery = LaunchRecovery(requested: resumeAfterLaunch)
        selectedProfile = min(2, max(0, UserDefaults.standard.integer(forKey: Self.selectedProfileKey)))
        if let data = UserDefaults.standard.data(forKey: Self.pointsKey(for: selectedProfile)),
           let saved = FanCurve.decodePoints(from: data) {
            points = saved
        } else {
            points = FanCurve.defaultPoints
        }
        temperatureHistory = UserDefaults.standard.data(forKey: Self.historyKey)
            .flatMap(TemperatureHistory.decode) ?? []
        super.init()

        UNUserNotificationCenter.current().delegate = self
        controlRecorder.record(ControlEvent(
            kind: .launched,
            message: Bundle.main.object(forInfoDictionaryKey: "FanCurveSourceRevision") as? String,
            thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState)
        ))

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
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
    private static func loadSceneBudgets() -> [FanBudget] {
        guard let data = UserDefaults.standard.data(forKey: sceneBudgetsKey),
              data.count <= 4_096,
              let saved = try? JSONDecoder().decode([FanBudget].self, from: data) else {
            return Array(repeating: .disabled, count: FanSceneCatalog.names.count)
        }
        return (0..<FanSceneCatalog.names.count).map { index in
            saved.indices.contains(index) ? saved[index] : .disabled
        }
    }

    private func saveSceneBudgets() {
        guard let data = try? JSONEncoder().encode(sceneBudgets) else { return }
        UserDefaults.standard.set(data, forKey: Self.sceneBudgetsKey)
    }

    var sceneName: String {
        FanSceneCatalog.names[selectedProfile]
    }

    var activeBudget: FanBudget {
        sceneBudgets[selectedProfile]
    }

    var budgetDescription: String {
        guard activeBudget.enabled else { return "Budget off" }
        let cap = "\(activeBudget.ceilingPercentage)% ceiling"
        let priority = "\(activeBudget.coolingPriority)% cooling priority"
        return budgetCapped ? "\(cap) · \(priority) · capped" : "\(cap) · \(priority)"
    }


    func updatePoints(_ newPoints: [CurvePoint]) {
        let sorted = newPoints.sorted { $0.temperature < $1.temperature }
        guard FanCurve.isValid(sorted), sorted != points else { return }
        points = sorted
        if let data = try? JSONEncoder().encode(points) {
            UserDefaults.standard.set(data, forKey: Self.pointsKey(for: selectedProfile))
        }
        refreshOutput(writeStateIfEnabled: true)
        onUpdate?()
    }

    func selectProfile(_ profile: Int) {
        guard !automaticScenes else {
            status = "Disable automatic scenes to choose manually"
            onUpdate?()
            return
        }
        guard (0..<FanSceneCatalog.names.count).contains(profile), profile != selectedProfile else { return }
        selectedProfile = profile
        UserDefaults.standard.set(profile, forKey: Self.selectedProfileKey)
        points = UserDefaults.standard.data(forKey: Self.pointsKey(for: profile))
            .flatMap(FanCurve.decodePoints) ?? FanCurve.defaultPoints
        refreshOutput(writeStateIfEnabled: true)
        status = "\(sceneName) scene selected"
        onUpdate?()
    }

    func setBudgetEnabled(_ enabled: Bool) {
        updateBudget { $0 = FanBudget(
            enabled: enabled,
            ceilingPercentage: $0.ceilingPercentage,
            coolingPriority: $0.coolingPriority
        ) }
    }

    func setBudgetCeiling(_ percentage: Int) {
        updateBudget { $0 = FanBudget(
            enabled: $0.enabled,
            ceilingPercentage: percentage,
            coolingPriority: $0.coolingPriority
        ) }
    }

    func setCoolingPriority(_ percentage: Int) {
        updateBudget { $0 = FanBudget(
            enabled: $0.enabled,
            ceilingPercentage: $0.ceilingPercentage,
            coolingPriority: percentage
        ) }
    }

    func setAutomaticScenes(_ enabled: Bool) {
        automaticScenes = enabled
        powerSource = Self.currentPowerSource()
        UserDefaults.standard.set(enabled, forKey: Self.automaticScenesKey)
        applyAutomaticSceneIfNeeded()
        status = enabled
            ? "Battery uses Quiet · AC/UPS/unknown uses Balanced"
            : "Automatic scenes disabled"
        onUpdate?()
    }

    private func updateBudget(_ update: (inout FanBudget) -> Void) {
        guard sceneBudgets.indices.contains(selectedProfile) else { return }
        update(&sceneBudgets[selectedProfile])
        saveSceneBudgets()
        refreshOutput(writeStateIfEnabled: true)
        status = budgetDescription
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

    private static func pointsKey(for profile: Int) -> String {
        profile == 0 ? pointsKey : "\(pointsKey).\(profile + 1)"
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
            guard let averageTemperature else {
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
            let curveTarget = Int(FanCurve(points: points).percentage(at: averageTemperature).rounded())
            let resolution = FanOutputResolver.resolve(
                curvePercentage: curveTarget,
                currentPercentage: outputPercentage,
                isEnabled: false,
                budget: activeBudget,
                advanceSmoothing: false
            )
            outputPercentage = resolution.percentage
            budgetCapped = resolution.budgetCapped
            writeState(enabled: true)
            guard isEnabled else { onUpdate?(); return }
            controlConfirmation.start(at: ProcessInfo.processInfo.systemUptime)
            status = "Waiting for background helper…"
            controlRecorder.record(ControlEvent(
                kind: .enabled,
                message: "Control requested",
                expectedPercentage: outputPercentage,
                temperature: averageTemperature,
                thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState)
            ))
        } else {
            controlIsActive = false
            writeState(enabled: false)
            status = reason ?? "Apple automatic control"
            controlRecorder.record(ControlEvent(
                kind: .disabled,
                message: status,
                expectedPercentage: outputPercentage,
                temperature: averageTemperature,
                thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState)
            ))
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
        supportLevel != .unsupported && bundledResource("install-helper.sh") != nil && !isBusy
    }

    var helperNeedsUpdate: Bool {
        guard helperInstalled, let bundledHelper = bundledResource("FanCurveHelper") else { return false }
        return !HelperInstallation.isCurrent(bundledHelperPath: bundledHelper.path)
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
                self.isBusy = false
                self.status = NSPasteboard.general.setString(report, forType: .string)
                    ? "Support report copied"
                    : "Could not copy support report"
                self.poll()
                self.onUpdate?()
            }
        }
    }

    func shutdown() {
        controlRecorder.record(ControlEvent(
            kind: .stopped,
            message: "App shutting down",
            expectedPercentage: outputPercentage,
            temperature: averageTemperature,
            thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState)
        ))
        timer?.invalidate()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        wakeRecovery.cancelResume()
        launchRecovery.cancelResume()
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
        let work = controlLoopSchedule.tick(isEnabled: isEnabled)
        if work.refreshHeartbeat { writeState(enabled: true) }
        guard work.startPoll else { return }
        guard !isBusy else {
            controlLoopSchedule.finishPoll()
            return
        }
        guard let isWakePoll = wakeRecovery.beginPoll() else {
            controlLoopSchedule.finishPoll()
            return
        }
        let expectedPercentage = outputPercentage
        let pollStartedAt = ProcessInfo.processInfo.systemUptime
        let acknowledgementPath = acknowledgementPath
        let statePath = statePath
        let bundledHelperPath = launchRecovery.isPending
            ? bundledResource("FanCurveHelper")?.path
            : nil
        worker.async { [weak self] in
            guard let self else { return }
            let availableKeys = self.availableSMCKeys ?? Set(SMC.shared.getAllKeys())
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
            let temperatureReadAt = ProcessInfo.processInfo.systemUptime
            if average != nil { self.availableSMCKeys = availableKeys }
            let active = Self.controlIsActive(
                acknowledgementPath: acknowledgementPath,
                fans: fans,
                fanTelemetry: fanTelemetry
            )
            let helperInstalled = HelperInstallation.isSecure()
            let helperIsCurrent = bundledHelperPath.map {
                HelperInstallation.isCurrent(bundledHelperPath: $0)
            } ?? false
            let powerSource = Self.currentPowerSource()
            let recordedAt = Date().timeIntervalSince1970
            let stateSnapshot = Self.stateSnapshot(path: statePath, at: recordedAt)
            let acknowledgementSnapshot = Self.acknowledgementSnapshot(
                path: acknowledgementPath,
                at: recordedAt
            )
            let fanSnapshots = fans.map { fan in
                let telemetry = fanTelemetry.first { $0.id == fan.id }
                return ControlFanSnapshot(
                    id: fan.id,
                    mode: telemetry?.mode.map(Self.fanModeName) ?? "unknown",
                    actualRPM: telemetry?.actualRPM,
                    targetRPM: telemetry?.targetRPM,
                    expectedRPM: Double(fan.rpm(at: expectedPercentage))
                )
            }
            let thermalState = Self.thermalStateName(ProcessInfo.processInfo.thermalState)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.controlLoopSchedule.finishPoll()
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
                let temperatureRate: Double?
                if let average,
                   let previousTemperature = self.averageTemperature,
                   let previousReadingAt = self.lastTemperatureReadingAt {
                    let elapsed = temperatureReadAt - previousReadingAt
                    temperatureRate = elapsed > 0
                        ? (average - previousTemperature) / elapsed
                        : nil
                } else {
                    temperatureRate = nil
                }
                self.averageTemperature = average
                self.lastTemperatureReadingAt = average == nil ? nil : temperatureReadAt
                self.detectedFanCount = fans.count
                self.supportLevel = supportLevel
                self.fanTelemetry = fanTelemetry
                self.helperInstalled = helperInstalled
                self.powerSource = powerSource
                let sceneChanged = self.applyAutomaticSceneIfNeeded()
                let controlIsCurrent = !sceneChanged && active
                let wasControlActive = self.controlIsActive
                self.controlIsActive = controlIsCurrent
                if self.isEnabled, !sceneChanged, wasControlActive != controlIsCurrent {
                    self.controlRecorder.record(ControlEvent(
                        kind: controlIsCurrent ? .controlRestored : .controlLost,
                        timestamp: recordedAt,
                        message: controlIsCurrent ? "Helper confirmation restored" : "Helper confirmation missing",
                        expectedPercentage: expectedPercentage,
                        state: stateSnapshot,
                        acknowledgement: acknowledgementSnapshot,
                        fans: fanSnapshots,
                        temperature: average,
                        pollDuration: ProcessInfo.processInfo.systemUptime - pollStartedAt,
                        thermalState: thermalState
                    ))
                }
                if launchResumeWasPending && !shouldResumeAfterLaunch {
                    self.status = "Launch resume skipped; check temperature, fans, and helper"
                }
                if shouldResume || shouldResumeAfterLaunch { self.setEnabled(true) }
                if controlIsCurrent {
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
                            isConfirmed: controlIsCurrent,
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
                            self.status = controlIsCurrent ? "Curve active" : "Waiting for background helper…"
                        }
                    }
                    self.refreshOutput(
                        advanceSmoothing: true,
                        temperatureRate: temperatureRate
                    )
                    if let average {
                        self.recordTemperature(
                            average,
                            fanPercentage: self.isEnabled && controlIsCurrent ? self.outputPercentage : nil
                        )
                    }
                    self.onUpdate?()
                }
                }
            }
        }

    private func prepareForSleep() {
        controlRecorder.record(ControlEvent(
            kind: .sleeping,
            message: isEnabled ? "Pausing active control for sleep" : "Sleeping while control is off",
            expectedPercentage: outputPercentage,
            temperature: averageTemperature,
            thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState)
        ))
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
        controlRecorder.record(ControlEvent(
            kind: .woke,
            message: "Waiting for the first temperature after wake",
            expectedPercentage: outputPercentage,
            thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState)
        ))
        status = "Waiting for temperature after wake…"
        poll()
        onUpdate?()
    }

    private func recordTemperature(_ temperature: Double, fanPercentage: Int?) {
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
        acknowledgementPath: String,
        fans: [FanRange],
        fanTelemetry: [FanTelemetry]
    ) -> Bool {
        guard let data = SecureRegularFile.read(
                  acknowledgementPath,
                  ownerUID: 0,
                  forbiddenPermissions: 0o022,
                  maxSize: 4_096
              ),
              let acknowledgement = try? JSONDecoder().decode(ControlAcknowledgement.self, from: data) else {
            return false
        }
        // The helper acknowledgement proves its last applied target. Fan telemetry
        // can race that acknowledgement, so only require the fans to remain forced here.
        let fanModesAreForced = ControlPolicy.fanModesAreForced(
            fans: fans,
            telemetry: fanTelemetry
        )
        return ControlPolicy.confirmationMatches(
            acknowledgement,
            ownerUID: getuid(),
            now: Date().timeIntervalSince1970,
            fanModesAreForced: fanModesAreForced
        )
    }

    private static func stateSnapshot(path: String, at time: TimeInterval) -> ControlStateSnapshot {
        let present = FileManager.default.fileExists(atPath: path)
        guard let data = SecureRegularFile.read(
                  path,
                  ownerUID: getuid(),
                  forbiddenPermissions: 0o077,
                  maxSize: 4_096
              ),
              let state = try? JSONDecoder().decode(ControlState.self, from: data),
              state.ownerUID == getuid() else {
            return ControlStateSnapshot(present: present, valid: false)
        }
        return ControlStateSnapshot(
            present: true,
            valid: true,
            enabled: state.enabled,
            percentage: state.percentage,
            heartbeatAge: time - state.heartbeat
        )
    }

    private static func acknowledgementSnapshot(
        path: String,
        at time: TimeInterval
    ) -> ControlAcknowledgementSnapshot {
        let present = FileManager.default.fileExists(atPath: path)
        guard let data = SecureRegularFile.read(
                  path,
                  ownerUID: 0,
                  forbiddenPermissions: 0o022,
                  maxSize: 4_096
              ),
              let acknowledgement = try? JSONDecoder().decode(ControlAcknowledgement.self, from: data),
              acknowledgement.ownerUID == getuid() else {
            return ControlAcknowledgementSnapshot(present: present, valid: false)
        }
        return ControlAcknowledgementSnapshot(
            present: true,
            valid: true,
            percentage: acknowledgement.percentage,
            heartbeatAge: time - acknowledgement.heartbeat
        )
    }

    private static func fanModeName(_ mode: HardwareFanMode) -> String {
        switch mode {
        case .automatic: "automatic"
        case .forced: "forced"
        case .system: "system"
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }


    private static func currentPowerSource() -> ScenePowerSource {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let raw = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as? String else {
            return .unknown
        }
        switch raw {
        case kIOPMACPowerKey:
            return .external
        case kIOPMBatteryPowerKey:
            return .battery
        case kIOPMUPSPowerKey:
            return .ups
        default:
            return .unknown
        }
    }

    @discardableResult
    private func applyAutomaticSceneIfNeeded() -> Bool {
        guard let profile = SceneSelection.profile(
            for: powerSource,
            automatic: automaticScenes
        ), profile != selectedProfile else { return false }
        selectedProfile = profile
        UserDefaults.standard.set(profile, forKey: Self.selectedProfileKey)
        points = UserDefaults.standard.data(forKey: Self.pointsKey(for: profile))
            .flatMap(FanCurve.decodePoints) ?? FanCurve.defaultPoints
        refreshOutput(writeStateIfEnabled: true)
        let source = switch powerSource {
        case .battery: "Battery"
        case .external: "AC power"
        case .ups: "UPS power"
        case .unknown: "unknown power (Balanced fallback)"
        }
        status = "Automatic \(sceneName) scene (\(source))"
        return true
    }

    private static func fanMode(_ id: Int) -> HardwareFanMode? {
        #if arch(arm64)
        return MacHardware.appleFanMode(SMC.shared.getValue(SMC.shared.fanModeKey(id)))
        #else
        return MacHardware.intelFanMode(SMC.shared.getValue("FS! "), fanID: id)
        #endif
    }

    private func refreshOutput(
        advanceSmoothing: Bool = false,
        writeStateIfEnabled: Bool = false,
        temperatureRate: Double? = nil
    ) {
        guard let averageTemperature else {
            outputPercentage = 0
            budgetCapped = false
            return
        }
        let curveTarget = Int(FanCurve(points: points).percentage(at: averageTemperature).rounded())
        let resolution = FanOutputResolver.resolve(
            curvePercentage: curveTarget,
            currentPercentage: outputPercentage,
            isEnabled: isEnabled,
            budget: activeBudget,
            advanceSmoothing: advanceSmoothing,
            temperatureRate: temperatureRate
        )
        outputPercentage = resolution.percentage
        budgetCapped = resolution.budgetCapped
        if isEnabled, (advanceSmoothing || writeStateIfEnabled) {
            writeState(enabled: true)
        }
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
            controlRecorder.record(ControlEvent(
                kind: .stateWriteFailed,
                message: error.localizedDescription,
                expectedPercentage: outputPercentage,
                temperature: averageTemperature,
                thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState)
            ))
        }
    }

}
