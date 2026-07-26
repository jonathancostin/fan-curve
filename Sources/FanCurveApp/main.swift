import AppKit
import FanCurveUI

extension FanController: FanCurveControlling {}

let application = NSApplication.shared
let delegate = AppDelegate(controller: FanController.shared)
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
