import Darwin
import FanCurveCore
import Foundation
import StatsSMC

private let heartbeatTimeout: TimeInterval = 5

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

guard getuid() == 0 else { fail("must run as root") }
guard CommandLine.arguments.count == 3,
      let ownerUID = UInt32(CommandLine.arguments[2]) else { fail("usage: FanCurveHelper STATE_PATH OWNER_UID") }

let statePath = CommandLine.arguments[1]
guard statePath == "/tmp/fancurve-\(ownerUID).json" else { fail("invalid state path") }

let lockPath = "/var/run/fancurve.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { fail("controller already running") }
defer { close(lockFD) }

let fans = detectedFans()
guard !fans.isEmpty else { fail("no valid fans found") }
defer { restoreAutomatic(fans) }

var lastPercentage: Int?
while true {
    guard let state = loadState(path: statePath, expectedUID: ownerUID) else { break }
    let heartbeatAge = Date().timeIntervalSince1970 - state.heartbeat
    guard
          state.enabled,
          (0...100).contains(state.percentage),
          heartbeatAge >= 0,
          heartbeatAge <= heartbeatTimeout else { break }

    let thermalState = ProcessInfo.processInfo.thermalState
    guard thermalState != .serious && thermalState != .critical else { break }

    if state.percentage != lastPercentage || !isApplied(state.percentage, to: fans) {
        guard apply(state.percentage, to: fans) else { break }
        lastPercentage = state.percentage
    }
    usleep(500_000)
}
