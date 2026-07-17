import AppKit
import FanCurveCore
import Foundation

final class CurveView: NSView {
    var points = FanCurve.defaultPoints { didSet { needsDisplay = true } }
    var currentTemperature: Double? { didSet { needsDisplay = true } }
    var onChange: (([CurvePoint]) -> Void)?
    private var selectedIndex: Int?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setAccessibilityRole(.group)
        setAccessibilityLabel("Temperature to fan speed graph. Drag a point or use arrow keys.")
    }

    required init?(coder: NSCoder) { nil }

    private var plot: CGRect { CGRect(x: 38, y: 12, width: bounds.width - 50, height: bounds.height - 42) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGrid()
        drawCurrentTemperature()
        drawCurve()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        selectedIndex = points.indices.min { distance(position(points[$0]), location) < distance(position(points[$1]), location) }
        updateSelected(at: location)
    }

    override func mouseDragged(with event: NSEvent) {
        updateSelected(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        selectedIndex = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let index = selectedIndex ?? points.indices.min(by: { points[$0].temperature < points[$1].temperature }) else {
            super.keyDown(with: event)
            return
        }
        selectedIndex = index
        var updated = points
        switch event.keyCode {
        case 123: updated[index].temperature -= 1
        case 124: updated[index].temperature += 1
        case 125: updated[index].percentage -= 1
        case 126: updated[index].percentage += 1
        default: return super.keyDown(with: event)
        }
        clampPoint(index, in: &updated)
        points = updated
        onChange?(updated)
    }

    private func updateSelected(at location: CGPoint) {
        guard let index = selectedIndex else { return }
        var updated = points
        updated[index].temperature = (30 + (location.x - plot.minX) / plot.width * 70).rounded()
        updated[index].percentage = ((plot.maxY - location.y) / plot.height * 100).rounded()
        clampPoint(index, in: &updated)
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

final class MainViewController: NSViewController {
    private let controller: FanController
    private let averageValue = NSTextField(labelWithString: "—")
    private let outputValue = NSTextField(labelWithString: "0%")
    private let statusLabel = NSTextField(labelWithString: "Apple automatic control")
    private let toggle = NSSwitch()
    private let graph = CurveView()

    init(controller: FanController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        graph.points = controller.points
        graph.onChange = { [weak controller] in controller?.updatePoints($0) }
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 255).isActive = true

        averageValue.font = .systemFont(ofSize: 30, weight: .semibold)
        outputValue.font = .systemFont(ofSize: 22, weight: .bold)
        outputValue.textColor = .controlAccentColor
        outputValue.alignment = .right

        let header = NSStackView(views: [metric("Average CPU", value: averageValue), metric("Fan output", value: outputValue, alignment: .right)])
        header.distribution = .fillEqually

        toggle.target = self
        toggle.action = #selector(toggleControl)
        let toggleLabel = NSTextField(labelWithString: "Use fan curve")
        toggleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let controlRow = NSStackView(views: [toggleLabel, NSView(), toggle])

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let minimumLabel = NSTextField(labelWithString: "0% = minimum RPM")
        minimumLabel.font = .systemFont(ofSize: 11)
        minimumLabel.textColor = .secondaryLabelColor
        minimumLabel.alignment = .right
        let statusRow = NSStackView(views: [statusLabel, NSView(), minimumLabel])

        let quit = NSButton(title: "Quit", target: self, action: #selector(quitApp))
        quit.bezelStyle = .rounded
        let quitRow = NSStackView(views: [NSView(), quit])

        let stack = NSStackView(views: [header, graph, controlRow, statusRow, quitRow])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            view.widthAnchor.constraint(equalToConstant: 430)
        ])
        refresh()
    }

    func refresh() {
        averageValue.stringValue = controller.averageTemperature.map { String(format: "%.1f°C", $0) } ?? "—"
        outputValue.stringValue = "\(controller.outputPercentage)%"
        statusLabel.stringValue = controller.status
        toggle.state = controller.isEnabled ? .on : .off
        graph.points = controller.points
        graph.currentTemperature = controller.averageTemperature
    }

    private func metric(_ title: String, value: NSTextField, alignment: NSTextAlignment = .left) -> NSView {
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = alignment
        let stack = NSStackView(views: [caption, value])
        stack.orientation = .vertical
        stack.alignment = alignment == .right ? .trailing : .leading
        return stack
    }

    @objc private func toggleControl() { controller.setEnabled(toggle.state == .on) }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = FanController.shared
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private lazy var content = MainViewController(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.contentViewController = content
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.toolTip = "Fan Curve"
        statusItem.button?.image = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "Fan Curve")
        statusItem.button?.imagePosition = .imageOnly
        controller.onUpdate = { [weak self] in self?.refresh() }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }

    private func refresh() {
        if popover.isShown { content.refresh() }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            content.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
