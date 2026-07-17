import Darwin
import FanCurveCore
import Foundation
import StatsSMC

private let heartbeatTimeout: TimeInterval = 5
private let activeMarkerPath = "/var/run/fancurve.active"
private var shouldStop: sig_atomic_t = 0

private func handleTermination(_ signal: Int32) {
    shouldStop = 1
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FanCurveHelper: \(message)\n".utf8))
    exit(1)
}

private func loadState(path: String, expectedUID: UInt32) -> ControlState? {
    var info = stat()
    guard lstat(path, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == expectedUID,
          (info.st_mode & 0o077) == 0,
          let data = FileManager.default.contents(atPath: path),
          let state = try? JSONDecoder().decode(ControlState.self, from: data),
          state.ownerUID == expectedUID else { return nil }
    return state
}

private func detectedFans() -> [FanRange] {
    guard let rawCount = SMC.shared.getValue("FNum"), rawCount >= 1, rawCount <= 8 else { return [] }
    let count = Int(rawCount)
    let fans: [FanRange] = (0..<count).compactMap { id in
        guard let rawMin = SMC.shared.getValue("F\(id)Mn"),
              let rawMax = SMC.shared.getValue("F\(id)Mx") else { return nil }
        let minimum = Int(rawMin.rounded())
        let maximum = Int(rawMax.rounded())
        guard minimum >= 0, maximum > minimum, maximum <= 20_000 else { return nil }
        return FanRange(id: id, minimumRPM: minimum, maximumRPM: maximum)
    }
    return fans.count == count ? fans : []
}

private func isAutomatic(_ fan: FanRange) -> Bool {
    guard let rawMode = SMC.shared.getValue(SMC.shared.fanModeKey(fan.id)),
          let mode = FanMode(rawValue: Int(rawMode)) else { return false }
    return mode.isAutomatic
}

private func restoreAutomatic(_ fans: [FanRange]) {
    while true {
        for fan in fans {
            SMC.shared.setFanMode(fan.id, mode: .automatic)
        }
        _ = SMC.shared.resetFanControl()
        usleep(250_000)
        if fans.allSatisfy(isAutomatic) { return }
    }
}

private func isApplied(_ percentage: Int, to fans: [FanRange]) -> Bool {
    fans.allSatisfy { fan in
        let target = fan.rpm(at: percentage)
        let mode = SMC.shared.getValue(SMC.shared.fanModeKey(fan.id))
        let actualTarget = SMC.shared.getValue("F\(fan.id)Tg")
        return mode == Double(FanMode.forced.rawValue) && actualTarget.map { abs($0 - Double(target)) <= 5 } == true
    }
}

private func apply(_ percentage: Int, to fans: [FanRange]) -> Bool {
    for _ in 0..<3 {
        for fan in fans {
            SMC.shared.setFanMode(fan.id, mode: .forced)
            SMC.shared.setFanSpeed(fan.id, speed: fan.rpm(at: percentage))
        }
        usleep(250_000)
        if isApplied(percentage, to: fans) { return true }
    }
    return false
}

private func hasActiveMarker() -> Bool {
    var info = stat()
    return lstat(activeMarkerPath, &info) == 0
        && (info.st_mode & S_IFMT) == S_IFREG
        && info.st_uid == 0
}

private func markControlActive() -> Bool {
    let descriptor = open(activeMarkerPath, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    return fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
}

private func clearActiveMarker() {
    unlink(activeMarkerPath)
}

private func writeAcknowledgement(_ state: ControlState, path: String) {
    let acknowledgement = ControlAcknowledgement(
        heartbeat: state.heartbeat,
        percentage: state.percentage,
        ownerUID: state.ownerUID
    )
    guard let data = try? JSONEncoder().encode(acknowledgement) else { return }
    let temporaryPath = path + ".new"
    do {
        try data.write(to: URL(fileURLWithPath: temporaryPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporaryPath)
        guard rename(temporaryPath, path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    } catch {
        unlink(temporaryPath)
    }
}

guard getuid() == 0 else { fail("must run as root") }
guard CommandLine.arguments.count == 4,
      CommandLine.arguments[1] == "--daemon",
      let ownerUID = UInt32(CommandLine.arguments[3]) else {
    fail("usage: FanCurveHelper --daemon STATE_PATH OWNER_UID")
}

let statePath = CommandLine.arguments[2]
guard statePath == "/tmp/fancurve-\(ownerUID).json" else { fail("invalid state path") }
let acknowledgementPath = "/var/run/fancurve-\(ownerUID).ack"

let lockPath = "/var/run/fancurve.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { fail("controller already running") }
defer { close(lockFD) }

let fans = detectedFans()
guard !fans.isEmpty else { fail("no valid fans found") }
signal(SIGTERM, handleTermination)
signal(SIGINT, handleTermination)

var controlling = hasActiveMarker()
defer {
    if controlling {
        restoreAutomatic(fans)
        clearActiveMarker()
    }
    unlink(acknowledgementPath)
}

while shouldStop == 0 {
    let state = loadState(path: statePath, expectedUID: ownerUID)
    let heartbeatAge = state.map { Date().timeIntervalSince1970 - $0.heartbeat }
    let thermalState = ProcessInfo.processInfo.thermalState
    let shouldControl = state?.enabled == true
        && state.map { (0...100).contains($0.percentage) } == true
        && heartbeatAge.map { $0 >= 0 && $0 <= heartbeatTimeout } == true
        && thermalState != .serious
        && thermalState != .critical

    if shouldControl, let state {
        let percentage = state.percentage
        if !controlling {
            controlling = markControlActive()
        }
        if controlling, !isApplied(percentage, to: fans) {
            if !apply(percentage, to: fans) {
                restoreAutomatic(fans)
                clearActiveMarker()
                controlling = false
            }
        }
        if controlling {
            writeAcknowledgement(state, path: acknowledgementPath)
        }
    } else {
        if controlling || hasActiveMarker() {
            restoreAutomatic(fans)
            clearActiveMarker()
            controlling = false
        }
        unlink(acknowledgementPath)
    }
    usleep(500_000)
}
