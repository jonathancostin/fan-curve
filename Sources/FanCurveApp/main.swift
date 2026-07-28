import AppKit
import Darwin
import FanCurveUI
import ServiceManagement

if CommandLine.arguments.dropFirst() == ["--enable-after-restart"] {
    do {
        if SMAppService.mainApp.status == .notRegistered {
            try SMAppService.mainApp.register()
        }
        guard SMAppService.mainApp.status == .enabled else {
            FileHandle.standardError.write(Data("Approve Fan Curve in System Settings > General > Login Items\n".utf8))
            exit(1)
        }
        UserDefaults.standard.set(true, forKey: FanController.resumeAfterLaunchKey)
        print("Fan Curve will launch and resume after login")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not enable launch at login: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let instanceLockPath = FileManager.default.temporaryDirectory
    .appendingPathComponent("com.jonathan.FanCurve.lock")
    .path
let instanceLock = open(
    instanceLockPath,
    O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
    S_IRUSR | S_IWUSR
)
guard instanceLock >= 0 else {
    FileHandle.standardError.write(Data("Fan Curve could not create its app lock\n".utf8))
    exit(1)
}
guard flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
    close(instanceLock)
    FileHandle.standardError.write(Data("Fan Curve is already running\n".utf8))
    exit(0)
}
defer { close(instanceLock) }

extension FanController: FanCurveControlling {}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate(controller: FanController.shared)
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    application.run()
}
