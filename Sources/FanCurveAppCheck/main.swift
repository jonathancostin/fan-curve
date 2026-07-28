import AppKit
import FanCurveCore
import Foundation
import FanCurveUI

@MainActor
func checkCurveActions() {
    let controller = TestController()
    let viewController = MainViewController(controller: controller, systemActions: TestSystemActions())
    viewController.loadView()
    precondition(viewController.view.fittingSize.height <= 660, "popover must fit a 768-pixel display with the Dock visible")
    controller.onUpdate = { viewController.refresh() }

    let graph: CurveView = require(find(CurveView.self, in: viewController.view), "curve graph")
    graph.frame = NSRect(x: 0, y: 0, width: 380, height: 225)
    let window = NSWindow(contentViewController: viewController)
    window.contentView?.layoutSubtreeIfNeeded()
    precondition(
        graph.accessibilityValue() as? String == "5 points; no point selected",
        "curve graph must expose its selection state"
    )
    graph.mouseDown(with: mouseEvent(.leftMouseDown, at: graph.convert(CGPoint(x: 200, y: 200), to: nil), in: window))
    precondition(controller.points == FanCurve.defaultPoints, "clicking empty graph space must not change the curve")
    graph.keyDown(with: keyEvent(keyCode: 0))
    precondition(graph.selectedPoint == nil, "non-arrow keys must not select a curve point")
    graph.mouseDown(with: mouseEvent(
        .leftMouseDown,
        at: graph.convert(CGPoint(x: 62, y: graph.bounds.maxY - 30), to: nil),
        in: window
    ))
    precondition(controller.points == FanCurve.defaultPoints, "selecting a point must not change the curve")
    precondition(
        graph.accessibilityValue() as? String == "35 degrees Celsius, 0 percent",
        "curve graph must expose the selected point"
    )
    graph.mouseDragged(with: mouseEvent(.leftMouseDragged, at: graph.convert(CGPoint(x: 80, y: 170), to: nil), in: window))
    precondition(controller.points != FanCurve.defaultPoints, "dragging must update the curve")

    require(button("Add Point", in: viewController.view), "Add Point").performClick(nil)
    precondition(controller.points.count == FanCurve.defaultPoints.count + 1, "Add Point must add one point")

    let temperatureField: NSTextField = require(
        controls(
            NSTextField.self,
            labelled: "Selected point temperature in degrees Celsius",
            in: viewController.view
        ).first,
        "temperature field"
    )
    let temperatureFieldTarget = nextTemperature(for: graph)
    temperatureField.stringValue = String(temperatureFieldTarget)
    let updatesBeforeTemperatureField = controller.pointUpdateCount
    temperatureField.sendAction(temperatureField.action, to: temperatureField.target)
    precondition(
        graph.selectedPoint?.temperature == temperatureFieldTarget
            && controller.pointUpdateCount == updatesBeforeTemperatureField + 1,
        "temperature field must set the selected point"
    )

    let temperatureStepper: NSStepper = require(
        controls(
            NSStepper.self,
            labelled: "Selected point temperature in degrees Celsius",
            in: viewController.view
        ).first,
        "temperature stepper"
    )
    let temperatureStepperTarget = nextTemperature(for: graph)
    temperatureStepper.doubleValue = temperatureStepperTarget
    let updatesBeforeTemperatureStepper = controller.pointUpdateCount
    temperatureStepper.sendAction(temperatureStepper.action, to: temperatureStepper.target)
    precondition(
        graph.selectedPoint?.temperature == temperatureStepperTarget
            && controller.pointUpdateCount == updatesBeforeTemperatureStepper + 1,
        "temperature stepper must set the selected point"
    )

    let percentageField: NSTextField = require(
        controls(
            NSTextField.self,
            labelled: "Selected point fan percentage",
            in: viewController.view
        ).first,
        "percentage field"
    )
    let percentageFieldTarget = nextPercentage(for: graph)
    percentageField.stringValue = String(percentageFieldTarget)
    let updatesBeforePercentageField = controller.pointUpdateCount
    percentageField.sendAction(percentageField.action, to: percentageField.target)
    precondition(
        graph.selectedPoint?.percentage == percentageFieldTarget
            && controller.pointUpdateCount == updatesBeforePercentageField + 1,
        "percentage field must set the selected point"
    )

    let percentageStepper: NSStepper = require(
        controls(
            NSStepper.self,
            labelled: "Selected point fan percentage",
            in: viewController.view
        ).first,
        "percentage stepper"
    )
    let percentageStepperTarget = nextPercentage(for: graph)
    percentageStepper.doubleValue = percentageStepperTarget
    let updatesBeforePercentageStepper = controller.pointUpdateCount
    percentageStepper.sendAction(percentageStepper.action, to: percentageStepper.target)
    precondition(
        graph.selectedPoint?.percentage == percentageStepperTarget
            && controller.pointUpdateCount == updatesBeforePercentageStepper + 1,
        "percentage stepper must set the selected point"
    )

    let liveTextTarget = nextTemperature(for: graph)
    temperatureField.stringValue = String(liveTextTarget)
    let updatesBeforeLiveText = controller.pointUpdateCount
    precondition(controller.pointUpdateCount == updatesBeforeLiveText, "typing must not apply a partial value")
    temperatureField.sendAction(temperatureField.action, to: temperatureField.target)
    precondition(
        graph.selectedPoint?.temperature == liveTextTarget
            && controller.pointUpdateCount == updatesBeforeLiveText + 1,
        "committing text must set the selected point once"
    )

    let updatesBeforeKeys = controller.pointUpdateCount
    for keyCode in [UInt16(123), 124, 125, 126] {
        graph.keyDown(with: keyEvent(keyCode: keyCode))
    }
    precondition(controller.pointUpdateCount == updatesBeforeKeys + 4, "all arrow keys must update the curve")

    let pointsBeforeInvalidEdit = controller.points
    let updatesBeforeInvalidEdit = controller.pointUpdateCount
    percentageField.stringValue = "not a number"
    percentageField.sendAction(percentageField.action, to: percentageField.target)
    precondition(
        controller.points == pointsBeforeInvalidEdit
            && controller.pointUpdateCount == updatesBeforeInvalidEdit,
        "invalid exact values must not change the curve"
    )

    require(button("Delete Point", in: viewController.view), "Delete Point").performClick(nil)
    precondition(controller.points.count == FanCurve.defaultPoints.count, "Delete Point must remove one point")

    require(button("Reset", in: viewController.view), "Reset").performClick(nil)
    precondition(
        controller.points == FanCurve.defaultPoints && graph.points == FanCurve.defaultPoints,
        "Reset must restore the graph and saved points"
    )

    let delete = require(button("Delete Point", in: viewController.view), "Delete Point")
    while delete.isEnabled {
        delete.performClick(nil)
    }
    precondition(
        controller.points.count == FanCurve.minimumPointCount && !delete.isEnabled,
        "Delete Point must stop at the minimum point count"
    )
}

@MainActor
func checkProfiles() {
    let controller = TestController()
    let viewController = MainViewController(controller: controller, systemActions: TestSystemActions())
    viewController.loadView()
    controller.onUpdate = { viewController.refresh() }

    controller.updatePoints(Array(FanCurve.defaultPoints.dropLast()))
    let firstProfile = controller.points
    let profiles = require(
        controls(NSSegmentedControl.self, labelled: "Saved profile", in: viewController.view).first,
        "saved profiles"
    )
    profiles.selectedSegment = 1
    profiles.sendAction(profiles.action, to: profiles.target)
    precondition(controller.selectedProfile == 1 && controller.points == FanCurve.defaultPoints)

    controller.updatePoints(Array(FanCurve.defaultPoints.dropFirst()))
    profiles.selectedSegment = 0
    profiles.sendAction(profiles.action, to: profiles.target)
    precondition(controller.points == firstProfile, "each profile must keep its own curve")
}

@MainActor
func checkButtons() {
    let controller = TestController()
    let system = TestSystemActions()
    let viewController = MainViewController(controller: controller, systemActions: system)
    viewController.loadView()

    for title in ["Copy Curve", "Paste Curve", "Copy Support Report", "Quit"] {
        require(button(title, in: viewController.view), title).performClick(nil)
    }

    require(button("Install Helper", in: viewController.view), "Install Helper").performClick(nil)
    controller.helperInstalled = true
    viewController.refresh()
    require(button("Repair Helper", in: viewController.view), "Repair Helper").performClick(nil)
    controller.helperNeedsUpdate = true
    viewController.refresh()
    let updateHelper = require(button("Update Helper", in: viewController.view), "Update Helper")
    updateHelper.performClick(nil)
    controller.isBusy = true
    viewController.refresh()
    precondition(!updateHelper.isEnabled, "helper action must be disabled while busy")

    precondition(controller.actions == ["copy", "paste", "report", "install", "install", "install"])
    precondition(system.quitCount == 1, "Quit must ask the system to close the app")
}

@MainActor
func checkToggles() {
    let controller = TestController()
    let system = TestSystemActions()
    let viewController = MainViewController(controller: controller, systemActions: system)
    viewController.loadView()

    let control = require(toggle("Use fan curve", in: viewController.view), "Use fan curve")
    control.state = .off
    control.performClick(nil)
    control.performClick(nil)
    precondition(controller.enabledChanges == [true, false], "control switch must enable and disable")

    controller.needsSupportConfirmation = true
    system.confirmControl = false
    control.performClick(nil)
    precondition(controller.enabledChanges == [true, false], "cancelled confirmation must not enable")
    system.confirmControl = true
    control.state = .off
    control.performClick(nil)
    precondition(controller.confirmCount == 1, "unverified control must record confirmation")
    precondition(controller.enabledChanges == [true, false, true], "confirmed control must enable")

    let resume = require(toggle("Resume curve after launch", in: viewController.view), "Resume curve")
    resume.state = .off
    resume.performClick(nil)
    resume.performClick(nil)
    precondition(controller.resumeChanges == [true, false], "resume switch must update its setting")

    let login = require(toggle("Launch at login", in: viewController.view), "Launch at login")
    system.requiresLoginApproval = true
    login.state = .off
    login.performClick(nil)
    precondition(controller.status == "Approve launch at login in System Settings")
    login.performClick(nil)
    precondition(controller.status == "Launch at login disabled")

    system.requiresLoginApproval = false
    login.performClick(nil)
    precondition(controller.status == "Launch at login enabled")

    system.loginError = TestError.failed
    system.launchAtLoginRequested = true
    login.state = .on
    login.performClick(nil)
    precondition(login.state == .on, "failed login change must restore the real setting")
    precondition(controller.status == "Could not change launch at login")
}

@MainActor
func checkHistoryControls() {
    let controller = TestController()
    let viewController = MainViewController(controller: controller, systemActions: TestSystemActions())
    viewController.loadView()
    let segments = TemperatureHistoryView.fanOutputSegments(in: [
        TemperatureSample(timestamp: 1, temperature: 50, fanPercentage: 20),
        TemperatureSample(timestamp: 2, temperature: 51),
        TemperatureSample(timestamp: 3, temperature: 52, fanPercentage: 30),
        TemperatureSample(timestamp: 4, temperature: 53, fanPercentage: 40)
    ])
    precondition(segments.map(\.count) == [1, 2], "automatic control must break the fan output line")

    let graph: TemperatureHistoryView = require(find(TemperatureHistoryView.self, in: viewController.view), "history graph")
    controller.temperatureHistory = [TemperatureSample(
        timestamp: Date().timeIntervalSince1970,
        temperature: 50
    )]
    viewController.refresh()
    precondition(
        (graph.accessibilityValue() as? String)?.contains("fan output not recorded") == true,
        "automatic history must explain missing fan output"
    )
    let range = require(
        controls(NSSegmentedControl.self, labelled: "History time range", in: viewController.view).first,
        "history time range"
    )
    precondition(range.selectedSegment == 1 && graph.duration == 60 * 60, "history must default to one hour")
    range.selectedSegment = 0
    range.sendAction(range.action, to: range.target)
    precondition(graph.duration == 15 * 60, "history range must update the graph")

    let fan = require(button("Fan output", in: viewController.view), "fan history toggle")
    precondition(fan.state == .on && graph.showsFanOutput, "fan history must start visible")
    fan.performClick(nil)
    precondition(!graph.showsFanOutput, "fan history toggle must hide the line")
}

@MainActor
func checkMenu() {
    _ = NSApplication.shared
    let controller = TestController()
    controller.averageTemperature = 71.4
    controller.detectedFanCount = 2
    let popover = TestPopover()
    let delegate = AppDelegate(
        controller: controller,
        systemActions: TestSystemActions(),
        popover: popover
    )
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

    let button = require(delegate.statusItem.button, "menu button")
    precondition(button.title == "71° · Automatic")
    precondition(button.action != nil, "menu button must have an action")

    button.performClick(nil)
    precondition(popover.showCount == 1, "menu button must open the popover")
    button.performClick(nil)
    precondition(popover.closeCount == 1, "menu button must close the popover")

    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    precondition(controller.shutdownCount == 1, "app quit must stop control")
}

@MainActor
private func button(_ title: String, in view: NSView) -> NSButton? {
    allSubviews(in: view).compactMap { $0 as? NSButton }.first { $0.title == title }
}

@MainActor
private func toggle(_ label: String, in view: NSView) -> NSSwitch? {
    controls(NSSwitch.self, labelled: label, in: view).first
}

@MainActor
private func controls<T: NSControl>(_ type: T.Type, labelled label: String, in view: NSView) -> [T] {
    allSubviews(in: view).compactMap { $0 as? T }.filter { $0.accessibilityLabel() == label }
}

@MainActor
private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    allSubviews(in: view).compactMap { $0 as? T }.first
}

@MainActor
private func allSubviews(in view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(allSubviews)
}

private func require<T>(_ value: T?, _ name: String) -> T {
    guard let value else { preconditionFailure("Missing \(name)") }
    return value
}

@MainActor
private func nextTemperature(for graph: CurveView) -> Double {
    let point = require(graph.selectedPoint, "selected point")
    let index = require(graph.points.firstIndex(of: point), "selected point index")
    let lower = index == 0 ? 30 : graph.points[index - 1].temperature + 2
    let upper = index == graph.points.count - 1 ? 100 : graph.points[index + 1].temperature - 2
    return point.temperature < upper ? min(upper, point.temperature + 1) : max(lower, point.temperature - 1)
}

@MainActor
private func nextPercentage(for graph: CurveView) -> Double {
    let point = require(graph.selectedPoint, "selected point")
    let index = require(graph.points.firstIndex(of: point), "selected point index")
    let lower = index == 0 ? 0 : graph.points[index - 1].percentage
    let upper = index == graph.points.count - 1 ? 100 : graph.points[index + 1].percentage
    return point.percentage < upper ? min(upper, point.percentage + 1) : max(lower, point.percentage - 1)
}

@MainActor
private func mouseEvent(_ type: NSEvent.EventType, at location: CGPoint, in window: NSWindow) -> NSEvent {
    require(NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    ), "mouse event")
}

private func keyEvent(keyCode: UInt16) -> NSEvent {
    require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    ), "key event")
}

private final class TestController: FanCurveControlling {
    var points = FanCurve.defaultPoints
    var selectedProfile = 0
    var profiles = Array(repeating: FanCurve.defaultPoints, count: 3)
    var averageTemperature: Double?
    var temperatureHistory: [TemperatureSample] = []
    var outputPercentage = 40
    var detectedFanCount = 2
    var supportLevel = DeviceSupportLevel.verified
    var fanTelemetry: [FanTelemetry] = []
    var isEnabled = false
    var controlIsActive = false
    var isBusy = false
    var helperInstalled = false
    var resumeAfterLaunch = false
    var status = "Apple automatic control"
    var onUpdate: (() -> Void)?
    var needsSupportConfirmation = false
    var canInstallHelper: Bool { !isBusy }
    var helperNeedsUpdate = false
    var canCopySupportReport: Bool { !isBusy }
    var actions: [String] = []
    var enabledChanges: [Bool] = []
    var resumeChanges: [Bool] = []
    var confirmCount = 0
    var shutdownCount = 0
    var pointUpdateCount = 0

    func updatePoints(_ points: [CurvePoint]) {
        self.points = points
        profiles[selectedProfile] = points
        pointUpdateCount += 1
    }

    func selectProfile(_ profile: Int) {
        selectedProfile = profile
        points = profiles[profile]
        onUpdate?()
    }

    func resetPoints() {
        points = FanCurve.defaultPoints
        onUpdate?()
    }

    func copyCurve() {
        actions.append("copy")
    }

    func pasteCurve() {
        actions.append("paste")
    }

    func showStatus(_ message: String) {
        status = message
    }

    func setEnabled(_ enabled: Bool, reason: String? = nil) {
        isEnabled = enabled
        enabledChanges.append(enabled)
    }

    func confirmUnverifiedDevice() {
        confirmCount += 1
    }

    func setResumeAfterLaunch(_ enabled: Bool) {
        resumeAfterLaunch = enabled
        resumeChanges.append(enabled)
    }

    func installHelper() {
        actions.append("install")
    }

    func copySupportReport() {
        actions.append("report")
    }

    func shutdown() {
        shutdownCount += 1
    }
}

private final class TestSystemActions: SystemActions {
    var launchAtLoginRequested = false
    var confirmControl = true
    var requiresLoginApproval = false
    var loginError: Error?
    var quitCount = 0

    func confirmUnverifiedControl() -> Bool {
        confirmControl
    }

    func setLaunchAtLogin(_ enabled: Bool) throws -> Bool {
        if let loginError { throw loginError }
        launchAtLoginRequested = enabled
        return enabled && requiresLoginApproval
    }

    func quit() {
        quitCount += 1
    }
}

private enum TestError: Error {
    case failed
}

private final class TestPopover: NSPopover {
    var showCount = 0
    var closeCount = 0

    override var isShown: Bool {
        showCount > closeCount
    }

    override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        showCount += 1
    }

    override func performClose(_ sender: Any?) {
        closeCount += 1
    }
}

await MainActor.run {
    checkCurveActions()
    checkProfiles()
    checkButtons()
    checkToggles()
    checkHistoryControls()
    checkMenu()
}
print("FanCurve app action checks passed")
