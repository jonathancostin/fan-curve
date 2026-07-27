import AppKit
import Darwin
import FanCurveUI
import ServiceManagement

if CommandLine.arguments.dropFirst() == ["--enable-after-restart"] {
    UserDefaults.standard.set(true, forKey: FanController.resumeAfterLaunchKey)
    do {
        if SMAppService.mainApp.status == .notRegistered {
            try SMAppService.mainApp.register()
        }
        guard SMAppService.mainApp.status == .enabled else {
            FileHandle.standardError.write(Data("Approve Fan Curve in System Settings > General > Login Items\n".utf8))
            exit(1)
        }
        print("Fan Curve will launch and resume after login")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not enable launch at login: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

extension FanController: FanCurveControlling {}

let application = NSApplication.shared
let delegate = AppDelegate(controller: FanController.shared)
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
