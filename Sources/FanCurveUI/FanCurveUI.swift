import AppKit
import FanCurveCore
import Foundation
import ServiceManagement

package protocol FanCurveControlling: AnyObject {
    var points: [CurvePoint] { get }
    var selectedProfile: Int { get }
    var sceneName: String { get }
    var averageTemperature: Double? { get }
    var temperatureHistory: [TemperatureSample] { get }
    var outputPercentage: Int { get }
    var detectedFanCount: Int { get }
    var supportLevel: DeviceSupportLevel { get }
    var fanTelemetry: [FanTelemetry] { get }
    var isEnabled: Bool { get }
    var controlIsActive: Bool { get }
    var isBusy: Bool { get }
    var helperInstalled: Bool { get }
    var resumeAfterLaunch: Bool { get }
    var sceneBudgets: [FanBudget] { get }
    var automaticScenes: Bool { get }
    var budgetCapped: Bool { get }
    var budgetDescription: String { get }
    var status: String { get }
    var onUpdate: (() -> Void)? { get set }
    var needsSupportConfirmation: Bool { get }
    var canInstallHelper: Bool { get }
    var helperNeedsUpdate: Bool { get }
    var canCopySupportReport: Bool { get }

    func updatePoints(_ points: [CurvePoint])
    func selectProfile(_ profile: Int)
    func setBudgetEnabled(_ enabled: Bool)
    func setBudgetCeiling(_ percentage: Int)
    func setCoolingPriority(_ percentage: Int)
    func setAutomaticScenes(_ enabled: Bool)
    func resetPoints()
    func copyCurve()
    func pasteCurve()
    func showStatus(_ message: String)
    func setEnabled(_ enabled: Bool, reason: String?)
    func confirmUnverifiedDevice()
    func setResumeAfterLaunch(_ enabled: Bool)
    func installHelper()
    func copySupportReport()
    func shutdown()
}

@MainActor
package protocol SystemActions {
    var launchAtLoginRequested: Bool { get }
    func confirmUnverifiedControl() -> Bool
    func setLaunchAtLogin(_ enabled: Bool) throws -> Bool
    func quit()
}

struct LiveSystemActions: SystemActions {
    var launchAtLoginRequested: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    func confirmUnverifiedControl() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Fan control is not verified on this Mac"
        alert.informativeText = "Fan Curve found known fan keys, but this Mac model has not passed the full device test. Enable it only while you can watch the fans and turn the curve off if they do not respond."
        alert.addButton(withTitle: "Enable Fan Curve")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func setLaunchAtLogin(_ enabled: Bool) throws -> Bool {
        if enabled {
            try SMAppService.mainApp.register()
            return SMAppService.mainApp.status == .requiresApproval
        }
        try SMAppService.mainApp.unregister()
        return false
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}

package final class CurveView: NSView {
    package var points = FanCurve.defaultPoints {
        didSet {
            if let selectedIndex, !points.indices.contains(selectedIndex) { self.selectedIndex = nil }
            needsDisplay = true
            refreshAccessibilityValue()
        }
    }
    var currentTemperature: Double? { didSet { needsDisplay = true } }
    var onChange: (([CurvePoint]) -> Void)?
    var onSelectionChange: (() -> Void)?
    private var selectedIndex: Int? {
        didSet { refreshAccessibilityValue() }
    }

    var canAddPoint: Bool { FanCurve.addingPoint(to: points) != nil }
    var canDeletePoint: Bool { selectedIndex != nil && points.count > FanCurve.minimumPointCount }
    package var selectedPoint: CurvePoint? { selectedIndex.map { points[$0] } }

    package override var acceptsFirstResponder: Bool { true }
    package override var isFlipped: Bool { true }

    package override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setAccessibilityRole(.group)
        setAccessibilityLabel("Temperature to fan speed graph. Drag a point or use arrow keys.")
        refreshAccessibilityValue()
    }

    package required init?(coder: NSCoder) { nil }

    private var plot: CGRect { CGRect(x: 38, y: 12, width: bounds.width - 50, height: bounds.height - 42) }

    package override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGrid()
        drawCurrentTemperature()
        drawCurve()
    }

    package override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        guard let index = points.indices.min(by: {
            distance(position(points[$0]), location) < distance(position(points[$1]), location)
        }), distance(position(points[index]), location) <= 12 else {
            selectedIndex = nil
            onSelectionChange?()
            return
        }
        selectedIndex = index
        onSelectionChange?()
    }

    package override func mouseDragged(with event: NSEvent) {
        updateSelected(at: convert(event.locationInWindow, from: nil))
    }

    package override func mouseUp(with event: NSEvent) {
        needsDisplay = true
    }

    func addPoint() {
        guard let updated = FanCurve.addingPoint(to: points) else { return }
        selectedIndex = updated.indices.first { index in
            !points.contains { $0.temperature == updated[index].temperature }
        }
        points = updated
        onChange?(updated)
        onSelectionChange?()
    }

    func deleteSelectedPoint() {
        guard let selectedIndex,
              let updated = FanCurve.deletingPoint(at: selectedIndex, from: points) else { return }
        self.selectedIndex = min(selectedIndex, updated.count - 1)
        points = updated
        onChange?(updated)
        onSelectionChange?()
    }

    package override func keyDown(with event: NSEvent) {
        guard (123...126).contains(Int(event.keyCode)) else {
            return super.keyDown(with: event)
        }
        guard let index = selectedIndex ?? points.indices.min(by: { points[$0].temperature < points[$1].temperature }) else {
            super.keyDown(with: event)
            return
        }
        if selectedIndex == nil {
            selectedIndex = index
            onSelectionChange?()
        }
        switch event.keyCode {
        case 123: updateSelected { $0.temperature -= 1 }
        case 124: updateSelected { $0.temperature += 1 }
        case 125: updateSelected { $0.percentage -= 1 }
        case 126: updateSelected { $0.percentage += 1 }
        default: break
        }
    }

    func updateSelected(temperature: Double? = nil, percentage: Double? = nil) {
        updateSelected {
            if let temperature { $0.temperature = temperature }
            if let percentage { $0.percentage = percentage }
        }
    }

    private func updateSelected(at location: CGPoint) {
        updateSelected {
            $0.temperature = (30 + (location.x - plot.minX) / plot.width * 70).rounded()
            $0.percentage = ((plot.maxY - location.y) / plot.height * 100).rounded()
        }
    }

    private func updateSelected(_ change: (inout CurvePoint) -> Void) {
        guard let index = selectedIndex else { return }
        var updated = points
        change(&updated[index])
        clampPoint(index, in: &updated)
        guard FanCurve.isValid(updated), updated != points else { return }
        points = updated
        onChange?(updated)
    }

    private func clampPoint(_ index: Int, in values: inout [CurvePoint]) {
        let lower = index == 0 ? 30 : values[index - 1].temperature + 2
        let upper = index == values.count - 1 ? 100 : values[index + 1].temperature - 2
        let minimumPercentage = index == 0 ? 0 : values[index - 1].percentage
        let maximumPercentage = index == values.count - 1 ? 100 : values[index + 1].percentage
        values[index].temperature = min(upper, max(lower, values[index].temperature))
        values[index].percentage = min(maximumPercentage, max(minimumPercentage, values[index].percentage))
    }

    private func position(_ point: CurvePoint) -> CGPoint {
        CGPoint(
            x: plot.minX + (point.temperature - 30) / 70 * plot.width,
            y: plot.maxY - point.percentage / 100 * plot.height
        )
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func refreshAccessibilityValue() {
        let value = selectedPoint.map {
            "\(Int($0.temperature)) degrees Celsius, \(Int($0.percentage)) percent"
        } ?? "\(points.count) points; no point selected"
        setAccessibilityValue(value)
    }

    private func drawGrid() {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        for percentage in stride(from: 0, through: 100, by: 25) {
            let y = plot.maxY - CGFloat(percentage) / 100 * plot.height
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.line(to: CGPoint(x: plot.maxX, y: y))
            line.stroke()
            ("\(percentage)%" as NSString).draw(at: CGPoint(x: 3, y: y - 6), withAttributes: attributes)
        }
        for temperature in stride(from: 30, through: 100, by: 10) {
            let x = plot.minX + CGFloat(temperature - 30) / 70 * plot.width
            ("\(temperature)°" as NSString).draw(at: CGPoint(x: x - 8, y: plot.maxY + 8), withAttributes: attributes)
        }
    }

    private func drawCurve() {
        guard let first = points.first else { return }
        let line = NSBezierPath()
        line.lineWidth = 3
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        line.move(to: position(first))
        points.dropFirst().forEach { line.line(to: position($0)) }
        NSColor.controlAccentColor.setStroke()
        line.stroke()

        for (index, point) in points.enumerated() {
            let center = position(point)
            let circle = NSBezierPath(ovalIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
            (index == selectedIndex ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
            circle.fill()
            NSColor.white.setStroke()
            circle.lineWidth = 2
            circle.stroke()
        }

        if let index = selectedIndex {
            let point = points[index]
            let text = "\(Int(point.temperature))° · \(Int(point.percentage))%" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
            let center = position(point)
            text.draw(at: CGPoint(x: min(plot.maxX - 65, max(plot.minX, center.x - 25)), y: max(0, center.y - 24)), withAttributes: attributes)
        }
    }

    private func drawCurrentTemperature() {
        guard let temperature = currentTemperature, (30...100).contains(temperature) else { return }
        let x = plot.minX + (temperature - 30) / 70 * plot.width
        let line = NSBezierPath()
        line.move(to: CGPoint(x: x, y: plot.minY))
        line.line(to: CGPoint(x: x, y: plot.maxY))
        line.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.systemOrange.withAlphaComponent(0.8).setStroke()
        line.stroke()
    }
}

package final class TemperatureHistoryView: NSView {
    private struct TelemetryMetric {
        let title: String
        let value: String
        let detail: String
        let color: NSColor
    }

    private struct HistorySummary {
        let samples: [TemperatureSample]
        let minimum: Double?
        let maximum: Double?
        let average: Double?
        let peak: TemperatureSample?
    }

    var samples: [TemperatureSample] = [] {
        didSet { refresh() }
    }
    package var currentTemperature: Double? { didSet { refresh() } }
    package var currentFanPercentage = 0 { didSet { refresh() } }
    package var fanTelemetry: [FanTelemetry] = [] { didSet { refresh() } }
    package var duration: TimeInterval = 60 * 60 { didSet { refresh() } }
    package var showsFanOutput = true { didSet { refresh() } }
    package override var isFlipped: Bool { true }

    package override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setAccessibilityRole(.group)
    }

    package required init?(coder: NSCoder) { nil }

    package override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawTelemetryStrip()
        let plot = CGRect(x: 34, y: 70, width: bounds.width - 68, height: bounds.height - 108)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let end = Date().timeIntervalSince1970
        let summary = historySummary(at: end)
        drawGrid(in: plot)
        drawPlotLabels(in: plot, attributes: attributes)
        guard summary.samples.count > 1 else {
            ("Collecting history…" as NSString).draw(
                at: CGPoint(x: plot.midX - 38, y: plot.midY - 6),
                withAttributes: attributes
            )
            drawHistoryFooter(summary, end: end)
            return
        }

        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        let start = end - duration
        for (index, sample) in summary.samples.enumerated() {
            let x = plot.minX + (sample.timestamp - start) / duration * plot.width
            let y = plot.maxY - min(1, max(0, (sample.temperature - 20) / 90)) * plot.height
            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.line(to: CGPoint(x: x, y: y))
        }
        NSColor.systemOrange.setStroke()
        path.stroke()

        if showsFanOutput {
            for segment in Self.fanOutputSegments(in: summary.samples) {
                let fanPath = NSBezierPath()
                fanPath.lineWidth = 2
                fanPath.lineJoinStyle = .round
                for (index, sample) in segment.enumerated() {
                    guard let percentage = sample.fanPercentage else { continue }
                    let x = plot.minX + (sample.timestamp - start) / duration * plot.width
                    let y = plot.maxY - min(1, max(0, CGFloat(percentage) / 100)) * plot.height
                    index == 0 ? fanPath.move(to: CGPoint(x: x, y: y)) : fanPath.line(to: CGPoint(x: x, y: y))
                }
                NSColor.systemBlue.setStroke()
                fanPath.stroke()
            }
        }

        drawHistoryFooter(summary, end: end)
    }

    private var durationText: String {
        duration < 60 * 60 ? "\(Int(duration / 60))m" : "\(Int(duration / 60 / 60))h"
    }

    package static func fanOutputSegments(in samples: [TemperatureSample]) -> [[TemperatureSample]] {
        samples.split { $0.fanPercentage == nil }.map(Array.init)
    }

    private func drawTelemetryStrip() {
        let metricWidth = bounds.width / 4
        let values = [
            TelemetryMetric(
                title: "CPU",
                value: currentTemperature.map { String(format: "%.1f°C", $0) } ?? "—",
                detail: "live average",
                color: .systemOrange
            ),
            TelemetryMetric(title: "OUTPUT", value: "\(currentFanPercentage)%", detail: "curve output", color: .systemBlue),
            fanMetric(id: 0, color: .systemGreen),
            fanMetric(id: 1, color: .systemPurple)
        ]
        for (index, metric) in values.enumerated() {
            let x = CGFloat(index) * metricWidth
            if index > 0 {
                NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
                let separator = NSBezierPath()
                separator.move(to: CGPoint(x: x, y: 10))
                separator.line(to: CGPoint(x: x, y: 48))
                separator.stroke()
            }
            (metric.title as NSString).draw(at: CGPoint(x: x + 8, y: 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            (metric.value as NSString).draw(at: CGPoint(x: x + 8, y: 25), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: metric.color
            ])
            (metric.detail as NSString).draw(at: CGPoint(x: x + 8, y: 42), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
        }
    }

    private func drawGrid(in plot: CGRect) {
        NSColor.separatorColor.withAlphaComponent(0.32).setStroke()
        for index in 0...4 {
            let y = plot.minY + CGFloat(index) / 4 * plot.height
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.line(to: CGPoint(x: plot.maxX, y: y))
            line.stroke()
        }
        for index in 0...6 {
            let x = plot.minX + CGFloat(index) / 6 * plot.width
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.line(to: CGPoint(x: x, y: plot.maxY))
            line.stroke()
        }
    }

    private func drawPlotLabels(in plot: CGRect, attributes: [NSAttributedString.Key: Any]) {
        ("TEMP °C" as NSString).draw(
            at: CGPoint(x: plot.minX, y: 56),
            withAttributes: attributes.merging([.foregroundColor: NSColor.systemOrange]) { _, new in new }
        )
        ("110°C" as NSString).draw(at: CGPoint(x: 2, y: plot.minY), withAttributes: attributes)
        ("20°C" as NSString).draw(at: CGPoint(x: 7, y: plot.maxY - 11), withAttributes: attributes)
        if showsFanOutput {
            let fanLabel = "OUTPUT %" as NSString
            fanLabel.draw(
                at: CGPoint(x: plot.maxX - fanLabel.size(withAttributes: attributes).width, y: 56),
                withAttributes: attributes.merging([.foregroundColor: NSColor.systemBlue]) { _, new in new }
            )
            ("100%" as NSString).draw(at: CGPoint(x: plot.maxX + 4, y: plot.minY), withAttributes: attributes)
            ("0%" as NSString).draw(at: CGPoint(x: plot.maxX + 4, y: plot.maxY - 11), withAttributes: attributes)
        }
        ("\(durationText) ago" as NSString).draw(at: CGPoint(x: plot.minX, y: plot.maxY - 11), withAttributes: attributes)
        let now = "now" as NSString
        now.draw(at: CGPoint(x: plot.maxX - now.size(withAttributes: attributes).width, y: plot.maxY - 11), withAttributes: attributes)
    }

    private func drawHistoryFooter(_ summary: HistorySummary, end: TimeInterval) {
        let separatorY = bounds.height - 28
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: 8, y: separatorY))
        separator.line(to: CGPoint(x: bounds.width - 8, y: separatorY))
        separator.stroke()

        let range = summary.minimum.flatMap { minimum in
            summary.maximum.map { maximum in String(format: "%.1f–%.1f°C", minimum, maximum) }
        } ?? "—"
        let averageText = summary.average.map { String(format: "%.1f°C", $0) } ?? "—"
        let peakText = summary.peak.map { relativeTime(end - $0.timestamp) } ?? "—"
        let footer: [(String, String)] = [("RANGE", range), ("AVG", averageText), ("PEAK", peakText)]
        let footerWidth = (bounds.width - 16) / 3
        for (index, item) in footer.enumerated() {
            let x = 8 + CGFloat(index) * footerWidth
            (item.0 as NSString).draw(at: CGPoint(x: x, y: separatorY + 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            let value = item.1 as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            value.draw(
                at: CGPoint(x: x + footerWidth - value.size(withAttributes: attributes).width - 4, y: separatorY + 7),
                withAttributes: attributes
            )
        }
    }

    private func fanMetric(id: Int, color: NSColor) -> TelemetryMetric {
        guard let fan = fanTelemetry.first(where: { $0.id == id }) else {
            return TelemetryMetric(title: "FAN \(id + 1) RPM", value: "—", detail: "not detected", color: color)
        }
        let live = fan.actualRPM.map {
            NumberFormatter.localizedString(from: NSNumber(value: $0.rounded()), number: .decimal)
        } ?? "—"
        let target = fan.targetRPM.map {
            NumberFormatter.localizedString(from: NSNumber(value: $0.rounded()), number: .decimal)
        } ?? "—"
        return TelemetryMetric(
            title: "FAN \(fan.id + 1) RPM",
            value: live,
            detail: "→ \(target) · \(fan.modeText.lowercased())",
            color: color
        )
    }

    private func relativeTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return "now" }
        if seconds < 60 * 60 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 60 / 60))h ago"
    }

    private func refresh() {
        needsDisplay = true
        let end = Date().timeIntervalSince1970
        let summary = historySummary(at: end)
        setAccessibilityLabel("History for the last \(durationText)")
        guard let latest = summary.samples.last,
              let minimum = summary.minimum,
              let maximum = summary.maximum,
              let average = summary.average else {
            setAccessibilityValue("No samples yet" + telemetryAccessibilityValue)
            return
        }
        let temperature = String(
            format: "Temperature %.1f degrees Celsius; range %.1f to %.1f; average %.1f",
            latest.temperature,
            minimum,
            maximum,
            average
        )
        let fanOutput = showsFanOutput
            ? latest.fanPercentage.map { "; fan output \($0) percent" } ?? "; fan output not recorded"
            : "; fan output hidden"
        setAccessibilityValue(temperature + fanOutput + telemetryAccessibilityValue)
    }

    private var telemetryAccessibilityValue: String {
        let current = currentTemperature.map {
            String(format: "; live CPU %.1f degrees Celsius; curve output %d percent", $0, currentFanPercentage)
        } ?? "; live CPU unavailable; curve output \(currentFanPercentage) percent"
        let fans = fanTelemetry.sorted { $0.id < $1.id }.map { fan in
            "; fan \(fan.id + 1) live \(fan.actualRPMText), target \(fan.targetRPMText), \(fan.modeText)"
        }.joined()
        return current + fans
    }

    private func historySummary(at end: TimeInterval) -> HistorySummary {
        let visibleSamples = samples.filter { (end - duration...end).contains($0.timestamp) }
        let temperatures = visibleSamples.map(\.temperature)
        return HistorySummary(
            samples: visibleSamples,
            minimum: temperatures.min(),
            maximum: temperatures.max(),
            average: temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count),
            peak: visibleSamples.max { $0.temperature < $1.temperature }
        )
    }
}

@MainActor
package final class MainViewController: NSViewController {
    private let controller: FanCurveControlling
    private let systemActions: SystemActions
    private let statusLabel = NSTextField(labelWithString: "Apple automatic control")
    private let toggle = NSSwitch()
    private let profileControl = NSSegmentedControl(labels: FanSceneCatalog.names, trackingMode: .selectOne, target: nil, action: nil)
    private let graph = CurveView()
    private let historyGraph = TemperatureHistoryView()
    private let historyRange = NSSegmentedControl(labels: ["15m", "1h", "6h", "24h"], trackingMode: .selectOne, target: nil, action: nil)
    private let fanHistoryToggle = NSButton(checkboxWithTitle: "Fan output", target: nil, action: nil)
    private let addPointButton = NSButton(title: "Add Point", target: nil, action: nil)
    private let deletePointButton = NSButton(title: "Delete Point", target: nil, action: nil)
    private let resetPointButton = NSButton(title: "Reset", target: nil, action: nil)
    private let temperatureField = NSTextField()
    private let temperatureStepper = NSStepper()
    private let percentageField = NSTextField()
    private let percentageStepper = NSStepper()
    private let copyCurveButton = NSButton(title: "Copy Curve", target: nil, action: nil)
    private let pasteCurveButton = NSButton(title: "Paste Curve", target: nil, action: nil)
    private let helperButton = NSButton(title: "Install Helper", target: nil, action: nil)
    private let copyReportButton = NSButton(title: "Copy Support Report", target: nil, action: nil)
    private let loginToggle = NSSwitch()
    private let resumeToggle = NSSwitch()
    private let budgetToggle = NSSwitch()
    private let budgetStatusLabel = NSTextField(labelWithString: "Budget off")
    private let budgetCeilingSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let budgetCeilingValue = NSTextField(labelWithString: "100%")
    private let coolingPrioritySlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let coolingPriorityValue = NSTextField(labelWithString: "0%")
    private let automaticScenesToggle = NSSwitch()
    private let contextLabel = NSTextField(labelWithString: "Battery → Quiet · AC → Balanced")
    private let hardwareLabel = NSTextField(labelWithString: "Checking hardware…")

    package init(controller: FanCurveControlling, systemActions: SystemActions? = nil) {
        self.controller = controller
        self.systemActions = systemActions ?? LiveSystemActions()
        super.init(nibName: nil, bundle: nil)
    }

    package required init?(coder: NSCoder) { nil }

    package override func loadView() {
        view = NSView()
        graph.points = controller.points
        graph.onChange = { [weak self, weak controller] in
            controller?.updatePoints($0)
            self?.refreshPointControls()
        }
        graph.onSelectionChange = { [weak self] in self?.refreshPointControls() }
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 170).isActive = true
        profileControl.selectedSegment = controller.selectedProfile
        profileControl.target = self
        profileControl.action = #selector(selectProfile)
        profileControl.setAccessibilityLabel("Scene")
        historyGraph.translatesAutoresizingMaskIntoConstraints = false
        historyGraph.heightAnchor.constraint(equalToConstant: 120).isActive = true
        historyRange.selectedSegment = 1
        historyRange.target = self
        historyRange.action = #selector(changeHistoryRange)
        historyRange.setAccessibilityLabel("History time range")
        fanHistoryToggle.state = .on
        fanHistoryToggle.target = self
        fanHistoryToggle.action = #selector(toggleFanHistory)
        fanHistoryToggle.controlSize = .small
        budgetToggle.target = self
        budgetToggle.action = #selector(toggleBudget)
        budgetToggle.setAccessibilityLabel("Use scene budget")
        budgetCeilingSlider.target = self
        budgetCeilingSlider.action = #selector(changeBudgetCeiling)
        budgetCeilingSlider.isContinuous = false
        budgetCeilingSlider.setAccessibilityLabel("Fan budget ceiling percentage")
        budgetCeilingValue.alignment = .right
        budgetCeilingValue.widthAnchor.constraint(equalToConstant: 38).isActive = true
        coolingPrioritySlider.target = self
        coolingPrioritySlider.action = #selector(changeCoolingPriority)
        coolingPrioritySlider.isContinuous = false
        coolingPrioritySlider.setAccessibilityLabel("Cooling priority percentage")
        coolingPriorityValue.alignment = .right
        coolingPriorityValue.widthAnchor.constraint(equalToConstant: 38).isActive = true
        automaticScenesToggle.target = self
        automaticScenesToggle.action = #selector(toggleAutomaticScenes)
        automaticScenesToggle.setAccessibilityLabel("Automatically choose scene on power")

        addPointButton.target = self
        addPointButton.action = #selector(addPoint)
        deletePointButton.target = self
        deletePointButton.action = #selector(deletePoint)
        resetPointButton.target = self
        resetPointButton.action = #selector(resetPoints)
        let temperatureLabel = NSTextField(labelWithString: "Temp")
        let percentageLabel = NSTextField(labelWithString: "Fan")
        for field in [temperatureField, percentageField] {
            field.alignment = .right
            field.controlSize = .small
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        temperatureField.target = self
        temperatureField.action = #selector(changePointTemperature)
        temperatureField.setAccessibilityLabel("Selected point temperature in degrees Celsius")
        percentageField.target = self
        percentageField.action = #selector(changePointPercentage)
        percentageField.setAccessibilityLabel("Selected point fan percentage")
        temperatureStepper.minValue = 30
        temperatureStepper.maxValue = 100
        temperatureStepper.increment = 1
        temperatureStepper.target = self
        temperatureStepper.action = #selector(changePointTemperature)
        temperatureStepper.setAccessibilityLabel("Selected point temperature in degrees Celsius")
        percentageStepper.minValue = 0
        percentageStepper.maxValue = 100
        percentageStepper.increment = 1
        percentageStepper.target = self
        percentageStepper.action = #selector(changePointPercentage)
        percentageStepper.setAccessibilityLabel("Selected point fan percentage")
        let pointEditRow = NSStackView(views: [
            temperatureLabel, temperatureField, temperatureStepper,
            NSTextField(labelWithString: "°C"),
            NSView(),
            percentageLabel, percentageField, percentageStepper,
            NSTextField(labelWithString: "%")
        ])
        copyCurveButton.target = self
        copyCurveButton.action = #selector(copyCurve)
        pasteCurveButton.target = self
        pasteCurveButton.action = #selector(pasteCurve)
        [addPointButton, deletePointButton, resetPointButton, copyCurveButton, pasteCurveButton].forEach {
            $0.controlSize = .small
        }
        toggle.setAccessibilityLabel("Use fan curve")
        budgetToggle.controlSize = .small
        let budgetLabel = NSTextField(labelWithString: "Scene budget")
        budgetLabel.font = .systemFont(ofSize: 13, weight: .medium)
        budgetStatusLabel.font = .systemFont(ofSize: 10)
        budgetStatusLabel.textColor = .secondaryLabelColor
        budgetStatusLabel.alignment = .right
        let budgetRow = NSStackView(views: [budgetLabel, budgetStatusLabel, budgetToggle])
        budgetStatusLabel.setAccessibilityLabel("Scene budget status")
        let ceilingRow = NSStackView(views: [
            NSTextField(labelWithString: "Fan budget ceiling"),
            budgetCeilingSlider,
            budgetCeilingValue
        ])
        let priorityRow = NSStackView(views: [
            NSTextField(labelWithString: "Cooling priority"),
            coolingPrioritySlider,
            coolingPriorityValue
        ])
        let automaticLabel = NSTextField(labelWithString: "Auto by power")
        automaticLabel.font = .systemFont(ofSize: 13, weight: .medium)
        contextLabel.font = .systemFont(ofSize: 10)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.alignment = .right
        let automaticRow = NSStackView(views: [automaticLabel, contextLabel, automaticScenesToggle])

        loginToggle.setAccessibilityLabel("Launch at login")
        resumeToggle.setAccessibilityLabel("Resume curve after launch")
        let pointRow = NSStackView(views: [
            addPointButton, deletePointButton, resetPointButton,
            NSView(),
            copyCurveButton, pasteCurveButton
        ])
        let profileLabel = NSTextField(labelWithString: "Scene")
        profileLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let profileRow = NSStackView(views: [profileLabel, NSView(), profileControl])
        toggle.target = self
        toggle.action = #selector(toggleControl)
        let toggleLabel = NSTextField(labelWithString: "Use fan curve")
        toggleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        helperButton.target = self
        helperButton.action = #selector(installHelper)
        let controlRow = NSStackView(views: [toggleLabel, NSView(), helperButton, toggle])

        loginToggle.target = self
        loginToggle.action = #selector(toggleLaunchAtLogin)
        let loginLabel = NSTextField(labelWithString: "Launch at login")
        loginLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let loginRow = NSStackView(views: [loginLabel, NSView(), loginToggle])

        resumeToggle.target = self
        resumeToggle.action = #selector(toggleResumeAfterLaunch)
        let resumeLabel = NSTextField(labelWithString: "Resume curve after launch")
        resumeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let resumeRow = NSStackView(views: [resumeLabel, NSView(), resumeToggle])

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        hardwareLabel.font = .systemFont(ofSize: 11)
        hardwareLabel.textColor = .secondaryLabelColor
        hardwareLabel.alignment = .right
        let statusRow = NSStackView(views: [statusLabel, NSView(), hardwareLabel])

        copyReportButton.target = self
        copyReportButton.action = #selector(copySupportReport)
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitApp))
        quit.bezelStyle = .rounded
        let quitRow = NSStackView(views: [copyReportButton, NSView(), quit])

        let historyLabel = NSTextField(labelWithString: "History")
        historyLabel.font = .systemFont(ofSize: 11, weight: .medium)
        let historyControls = NSStackView(views: [
            historyLabel, historyRange, NSView(), fanHistoryToggle
        ])

        let stack = NSStackView(views: [
            profileRow, graph, pointEditRow, pointRow,
            historyControls, historyGraph, controlRow,
            budgetRow, ceilingRow, priorityRow, automaticRow,
            loginRow, resumeRow, statusRow, quitRow
        ])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            view.widthAnchor.constraint(equalToConstant: 430)
        ])
        refresh()
    }

    package func refresh() {
        let helperNeedsUpdate = controller.helperNeedsUpdate
        statusLabel.stringValue = controller.status
        toggle.state = controller.isEnabled ? .on : .off
        toggle.isEnabled = !controller.isBusy
        profileControl.isEnabled = !controller.isBusy && !controller.automaticScenes
        helperButton.title = helperNeedsUpdate
            ? "Update Helper"
            : controller.helperInstalled ? "Repair Helper" : "Install Helper"
        helperButton.isEnabled = controller.canInstallHelper
        copyReportButton.isEnabled = controller.canCopySupportReport
        resetPointButton.isEnabled = !controller.isBusy
        pasteCurveButton.isEnabled = !controller.isBusy
        loginToggle.state = systemActions.launchAtLoginRequested ? .on : .off
        resumeToggle.state = controller.resumeAfterLaunch ? .on : .off
        let budget = controller.sceneBudgets.indices.contains(controller.selectedProfile)
            ? controller.sceneBudgets[controller.selectedProfile]
            : .disabled
        budgetToggle.state = budget.enabled ? .on : .off
        budgetStatusLabel.stringValue = controller.budgetDescription
        budgetToggle.isEnabled = !controller.isBusy
        budgetCeilingSlider.integerValue = budget.ceilingPercentage
        budgetCeilingSlider.isEnabled = budget.enabled && !controller.isBusy
        budgetCeilingValue.stringValue = "\(budget.ceilingPercentage)%"
        coolingPrioritySlider.integerValue = budget.coolingPriority
        coolingPrioritySlider.isEnabled = budget.enabled && !controller.isBusy
        coolingPriorityValue.stringValue = "\(budget.coolingPriority)%"
        automaticScenesToggle.state = controller.automaticScenes ? .on : .off
        automaticScenesToggle.isEnabled = !controller.isBusy
        contextLabel.stringValue = controller.automaticScenes
            ? "Battery → Quiet · AC/UPS/unknown → Balanced"
            : "Automatic scene switching off"
        let fanText = controller.detectedFanCount == 1 ? "1 fan" : "\(controller.detectedFanCount) fans"
        let helperText = helperNeedsUpdate
            ? "helper update needed"
            : controller.helperInstalled ? "helper installed" : "helper needed"
        hardwareLabel.stringValue = "\(controller.supportLevel.rawValue) · \(fanText) · \(helperText) · 0% = min"
        graph.points = controller.points
        profileControl.selectedSegment = controller.selectedProfile
        graph.currentTemperature = controller.averageTemperature
        historyGraph.samples = controller.temperatureHistory
        historyGraph.currentTemperature = controller.averageTemperature
        historyGraph.currentFanPercentage = controller.outputPercentage
        historyGraph.fanTelemetry = controller.fanTelemetry
        refreshPointControls()
    }

    @objc private func toggleBudget() {
        controller.setBudgetEnabled(budgetToggle.state == .on)
    }
    @objc private func changeBudgetCeiling() {
        controller.setBudgetCeiling(budgetCeilingSlider.integerValue)
    }
    @objc private func changeCoolingPriority() {
        controller.setCoolingPriority(coolingPrioritySlider.integerValue)
    }
    @objc private func toggleAutomaticScenes() {
        controller.setAutomaticScenes(automaticScenesToggle.state == .on)
    }
    @objc private func toggleControl() {
        guard toggle.state == .on, controller.needsSupportConfirmation else {
            controller.setEnabled(toggle.state == .on, reason: nil)
            return
        }
        guard systemActions.confirmUnverifiedControl() else {
            refresh()
            return
        }
        controller.confirmUnverifiedDevice()
        controller.setEnabled(true, reason: nil)
    }
    @objc private func addPoint() { graph.addPoint() }
    @objc private func selectProfile() { controller.selectProfile(profileControl.selectedSegment) }
    @objc private func deletePoint() { graph.deleteSelectedPoint() }
    @objc private func resetPoints() { controller.resetPoints() }
    @objc private func changePointTemperature(_ sender: NSControl) {
        guard let value = pointValue(from: sender) else { return refreshPointControls() }
        graph.updateSelected(temperature: value)
    }
    @objc private func changePointPercentage(_ sender: NSControl) {
        guard let value = pointValue(from: sender) else { return refreshPointControls() }
        graph.updateSelected(percentage: value)
    }
    @objc private func copyCurve() { controller.copyCurve() }
    @objc private func pasteCurve() { controller.pasteCurve() }
    @objc private func installHelper() { controller.installHelper() }
    @objc private func copySupportReport() { controller.copySupportReport() }
    @objc private func changeHistoryRange() {
        historyGraph.duration = [15, 60, 6 * 60, 24 * 60][historyRange.selectedSegment] * 60
    }
    @objc private func toggleFanHistory() {
        historyGraph.showsFanOutput = fanHistoryToggle.state == .on
    }
    @objc private func toggleResumeAfterLaunch() {
        controller.setResumeAfterLaunch(resumeToggle.state == .on)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            let enabled = loginToggle.state == .on
            let requiresApproval = try systemActions.setLaunchAtLogin(enabled)
            if enabled {
                controller.showStatus(
                    requiresApproval
                        ? "Approve launch at login in System Settings"
                        : "Launch at login enabled"
                )
            } else {
                controller.showStatus("Launch at login disabled")
            }
        } catch {
            loginToggle.state = systemActions.launchAtLoginRequested ? .on : .off
            controller.showStatus("Could not change launch at login")
        }
    }
    @objc private func quitApp() { systemActions.quit() }

    private func refreshPointControls() {
        addPointButton.isEnabled = graph.canAddPoint
        deletePointButton.isEnabled = graph.canDeletePoint
        let enabled = graph.selectedPoint != nil
        [temperatureField, temperatureStepper, percentageField, percentageStepper].forEach { $0.isEnabled = enabled }
        guard let point = graph.selectedPoint else {
            temperatureField.stringValue = ""
            percentageField.stringValue = ""
            return
        }
        if temperatureField.currentEditor() == nil {
            temperatureField.stringValue = String(format: "%g", point.temperature)
        }
        temperatureStepper.doubleValue = point.temperature
        if percentageField.currentEditor() == nil {
            percentageField.stringValue = String(format: "%g", point.percentage)
        }
        percentageStepper.doubleValue = point.percentage
    }

    private func pointValue(from control: NSControl) -> Double? {
        let value = control is NSTextField ? Double(control.stringValue) : control.doubleValue
        return value?.isFinite == true ? value : nil
    }
}

@MainActor
package final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: FanCurveControlling
    private let systemActions: SystemActions
    package let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    package let popover: NSPopover
    private lazy var content = MainViewController(controller: controller, systemActions: systemActions)

    package init(
        controller: FanCurveControlling,
        systemActions: SystemActions? = nil,
        popover: NSPopover? = nil
    ) {
        self.controller = controller
        self.systemActions = systemActions ?? LiveSystemActions()
        self.popover = popover ?? NSPopover()
    }

    package func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.contentViewController = content
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.image = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "Fan Curve")
        statusItem.button?.imagePosition = .imageLeading
        controller.onUpdate = { [weak self] in self?.refresh() }
        refresh()
    }

    package func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }

    private func refresh() {
        if popover.isShown { content.refresh() }
        guard let button = statusItem.button else { return }
        let temperature = controller.averageTemperature.map { Int($0.rounded()) }
        let state = ControlDisplayState(
            hasTemperature: temperature != nil,
            fanCount: controller.detectedFanCount,
            isEnabled: controller.isEnabled,
            isActive: controller.controlIsActive
        )
        let title = "\(temperature.map { "\($0)°" } ?? "—") · \(state.rawValue)"
        guard button.title != title else { return }
        let label = "Fan Curve, \(temperature.map { "\($0) degrees Celsius" } ?? "temperature unavailable"), \(state.rawValue)"
        button.title = title
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    @objc package func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            content.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
