import FanCurveCore
import Foundation

let curve = FanCurve(points: [
    CurvePoint(temperature: 40, percentage: 10),
    CurvePoint(temperature: 60, percentage: 50),
    CurvePoint(temperature: 80, percentage: 90)
])
precondition(curve.percentage(at: 20) == 10)
precondition(curve.percentage(at: 50) == 30)
precondition(curve.percentage(at: 100) == 90)
precondition(FanCurve.isValid(FanCurve.defaultPoints))
precondition(!FanCurve.isValid([
    CurvePoint(temperature: 40, percentage: 80),
    CurvePoint(temperature: 60, percentage: 20)
]))
precondition(!FanCurve.isValid([
    CurvePoint(temperature: 40, percentage: 20),
    CurvePoint(temperature: 41, percentage: 30)
]))
precondition(!FanCurve.isValid([CurvePoint(temperature: 40, percentage: 20)]))

let sharedCurve = [
    CurvePoint(temperature: 40, percentage: 10),
    CurvePoint(temperature: 60, percentage: 50)
]
precondition(FanCurve.decodePoints(from: try! JSONEncoder().encode(sharedCurve)) == sharedCurve)
precondition(FanCurve.decodePoints(from: Data("not json".utf8)) == nil)
precondition(FanCurve.decodePoints(from: try! JSONEncoder().encode([
    CurvePoint(temperature: 40, percentage: 80),
    CurvePoint(temperature: 60, percentage: 20)
])) == nil)

let added = FanCurve.addingPoint(to: [
    CurvePoint(temperature: 40, percentage: 20),
    CurvePoint(temperature: 60, percentage: 40),
    CurvePoint(temperature: 90, percentage: 100)
])!
precondition(added == [
    CurvePoint(temperature: 40, percentage: 20),
    CurvePoint(temperature: 60, percentage: 40),
    CurvePoint(temperature: 75, percentage: 70),
    CurvePoint(temperature: 90, percentage: 100)
])
precondition(FanCurve.deletingPoint(at: 2, from: added) == [
    CurvePoint(temperature: 40, percentage: 20),
    CurvePoint(temperature: 60, percentage: 40),
    CurvePoint(temperature: 90, percentage: 100)
])
precondition(FanCurve.deletingPoint(at: 0, from: Array(added.prefix(2))) == nil)
precondition(FanCurve.addingPoint(to: [
    CurvePoint(temperature: 40, percentage: 20),
    CurvePoint(temperature: 42, percentage: 40)
]) == nil)
precondition(FanCurve.addingPoint(to: [
    CurvePoint(temperature: 30.1, percentage: 20),
    CurvePoint(temperature: 34.1, percentage: 40)
]) == [
    CurvePoint(temperature: 30.1, percentage: 20),
    CurvePoint(temperature: 32.1, percentage: 30),
    CurvePoint(temperature: 34.1, percentage: 40)
])

let fan = FanRange(id: 0, minimumRPM: 2_000, maximumRPM: 8_000)
precondition(fan.rpm(at: -1) == 2_000)
precondition(fan.rpm(at: 50) == 5_000)
precondition(fan.rpm(at: 101) == 8_000)

let temperatures = [
    "Tp01": 60.0,
    "Tf04": 80.0,
    "Tg0U": 100.0,
    "TC0D": 50.0,
    "TC3C": 70.0
]
#if arch(arm64)
let temperatureSnapshot = MacHardware.cpuTemperatureSnapshot(
    availableKeys: Set(temperatures.keys),
    read: { temperatures[$0] }
)
precondition(temperatureSnapshot?.average == 70)
precondition(temperatureSnapshot?.sensorKeys == ["Tf04", "Tp01"])
#else
let temperatureSnapshot = MacHardware.cpuTemperatureSnapshot(
    availableKeys: Set(temperatures.keys),
    read: { temperatures[$0] }
)
precondition(temperatureSnapshot?.average == 70)
precondition(temperatureSnapshot?.sensorKeys == ["TC3C"])
#endif

#if arch(x86_64)
let intelFallbackTemperatures = ["TCAD": 65.0, "TC0D": 55.0]
precondition(MacHardware.averageCPUTemperature(
    availableKeys: Set(intelFallbackTemperatures.keys),
    read: { intelFallbackTemperatures[$0] }
) == 65)
#endif

let invalidTemperatures = [
    "Tp01": Double.nan,
    "Tp05": 111.0,
    "TC0D": Double.nan,
    "TC0P": 111.0
]
precondition(MacHardware.averageCPUTemperature(
    availableKeys: Set(invalidTemperatures.keys),
    read: { invalidTemperatures[$0] }
) == nil)

for count in 1...8 {
    var values = ["FNum": Double(count)]
    for id in 0..<count {
        values["F\(id)Mn"] = Double(1_000 + id)
        values["F\(id)Mx"] = Double(8_000 + id)
    }
    precondition(MacHardware.fanRanges(read: { values[$0] }).count == count)
}
let threeFans = (0..<3).map { FanRange(id: $0, minimumRPM: 1_000, maximumRPM: 8_000) }
#if arch(arm64)
precondition(MacHardware.supportsFanControl(threeFans, readMode: { _ in .automatic }))
#else
precondition(!MacHardware.supportsFanControl(threeFans, readMode: { _ in .automatic }))
#endif
precondition(!MacHardware.supportsFanControl(
    [FanRange(id: 0, minimumRPM: 1_000, maximumRPM: 8_000)],
    readMode: { _ in nil }
))
precondition(MacHardware.supportLevel(model: "Mac17,9", fanCount: 2, fanControlSupported: true) == .verified)
precondition(MacHardware.supportLevel(model: "Mac17,9", fanCount: 1, fanControlSupported: true) == .unsupported)
precondition(MacHardware.supportLevel(model: "Mac16,1", fanCount: 1, fanControlSupported: true) == .knownKeys)
precondition(MacHardware.supportLevel(model: "Mac17,9", fanCount: 2, fanControlSupported: false) == .unsupported)
let invalidFanData: [[String: Double]] = [
    ["FNum": 0],
    ["FNum": 9],
    ["FNum": 1.5],
    ["FNum": .greatestFiniteMagnitude],
    ["FNum": 1, "F0Mn": 1_000],
    ["FNum": 1, "F0Mn": -1, "F0Mx": 8_000],
    ["FNum": 1, "F0Mn": 8_000, "F0Mx": 8_000],
    ["FNum": 1, "F0Mn": 1_000, "F0Mx": 20_001],
    ["FNum": 1, "F0Mn": 1_000, "F0Mx": .greatestFiniteMagnitude]
]
precondition(invalidFanData.allSatisfy { values in
    MacHardware.fanRanges(read: { values[$0] }).isEmpty
})

precondition(MacHardware.appleFanMode(0) == .automatic)
precondition(MacHardware.appleFanMode(1) == .forced)
precondition(MacHardware.appleFanMode(3) == .system)
precondition(MacHardware.appleFanMode(2) == nil)
precondition(MacHardware.appleFanMode(.nan) == nil)
precondition(MacHardware.intelFanMode(0, fanID: 0) == .automatic)
precondition(MacHardware.intelFanMode(1, fanID: 0) == .forced)
precondition(MacHardware.intelFanMode(1, fanID: 1) == .automatic)
precondition(MacHardware.intelFanMode(2, fanID: 1) == .forced)
precondition(MacHardware.intelFanMode(3, fanID: 2) == nil)

let fanTelemetry = FanTelemetry(id: 0, actualRPM: 2_345.4, targetRPM: .nan, mode: .forced)
precondition(
    fanTelemetry.actualRPMText == "2345 RPM"
        && fanTelemetry.targetRPMText == "—"
        && fanTelemetry.modeText == "Forced"
)

let validState = ControlState(enabled: true, percentage: 50, heartbeat: 100, ownerUID: 501)
precondition(ControlPolicy.allowsControl(
    state: validState,
    now: 104,
    thermalPressureIsSafe: true
))
precondition(!ControlPolicy.allowsControl(
    state: validState,
    now: 106,
    thermalPressureIsSafe: true
))
precondition(!ControlPolicy.allowsControl(
    state: validState,
    now: 99,
    thermalPressureIsSafe: true
))
precondition(!ControlPolicy.allowsControl(
    state: validState,
    now: 104,
    heartbeatTimeout: .infinity,
    thermalPressureIsSafe: true
))
precondition(!ControlPolicy.allowsControl(
    state: ControlState(enabled: false, percentage: 50, heartbeat: 100, ownerUID: 501),
    now: 104,
    thermalPressureIsSafe: true
))
precondition(!ControlPolicy.allowsControl(
    state: validState,
    now: 104,
    thermalPressureIsSafe: false
))
precondition(!ControlPolicy.allowsControl(
    state: ControlState(enabled: true, percentage: 101, heartbeat: 100, ownerUID: 501),
    now: 104,
    thermalPressureIsSafe: true
))

let acknowledgement = ControlAcknowledgement(heartbeat: 100, percentage: 50, ownerUID: 501)
precondition(ControlPolicy.acknowledgementMatches(
    acknowledgement,
    expectedPercentage: 50,
    ownerUID: 501,
    now: 102
))
precondition(!ControlPolicy.acknowledgementMatches(
    acknowledgement,
    expectedPercentage: 49,
    ownerUID: 501,
    now: 102
))
precondition(!ControlPolicy.acknowledgementMatches(
    acknowledgement,
    expectedPercentage: 50,
    ownerUID: 501,
    now: 103
))
precondition(!ControlPolicy.acknowledgementMatches(
    acknowledgement,
    expectedPercentage: 50,
    ownerUID: 502,
    now: 102
))
precondition(!ControlPolicy.acknowledgementMatches(
    acknowledgement,
    expectedPercentage: 50,
    ownerUID: 501,
    now: 102,
    heartbeatTimeout: .infinity
))

var confirmation = ControlConfirmationDeadline()
confirmation.start(at: 100)
precondition(confirmation.failure(isConfirmed: false, at: 103.9) == nil)
precondition(confirmation.failure(isConfirmed: true, at: 104) == .neverConfirmed)
confirmation.start(at: 200)
precondition(confirmation.failure(isConfirmed: true, at: 201) == nil)
precondition(confirmation.failure(isConfirmed: false, at: 202) == nil)
precondition(confirmation.failure(isConfirmed: true, at: 206) == .lost)

var activeControlTransition = ActiveControlTransition()
precondition([
    activeControlTransition.shouldNotify(isEnabled: true, isActive: false),
    activeControlTransition.shouldNotify(isEnabled: true, isActive: true),
    activeControlTransition.shouldNotify(isEnabled: true, isActive: false),
    activeControlTransition.shouldNotify(isEnabled: true, isActive: false),
    activeControlTransition.shouldNotify(isEnabled: true, isActive: true),
    activeControlTransition.shouldNotify(isEnabled: false, isActive: false)
] == [false, false, true, false, false, false])

precondition(!HelperInstallation.isSecure(
    helperPath: "/nonexistent/fancurve-helper",
    launchDaemonPath: "/nonexistent/fancurve-helper.plist"
))
precondition(!HelperInstallation.requiresUpdate(bundledSHA256: nil, installedSHA256: "old"))
precondition(!HelperInstallation.requiresUpdate(bundledSHA256: "same", installedSHA256: "same"))
precondition(HelperInstallation.requiresUpdate(bundledSHA256: "new", installedSHA256: "old"))

precondition(FanSmoothing.next(current: 20, target: 80) == 25)
precondition(FanSmoothing.next(current: 80, target: 20) == 78)
precondition(FanSmoothing.next(current: 50, target: 53) == 53)
precondition(FanSmoothing.next(current: 50, target: 52) == 50)

precondition(ControlDisplayState(hasTemperature: false, fanCount: 2, isEnabled: false, isActive: false) == .problem)
precondition(ControlDisplayState(hasTemperature: true, fanCount: 0, isEnabled: false, isActive: false) == .problem)
precondition(ControlDisplayState(hasTemperature: true, fanCount: 2, isEnabled: false, isActive: false) == .automatic)
precondition(ControlDisplayState(hasTemperature: true, fanCount: 2, isEnabled: false, isActive: true) == .problem)
precondition(ControlDisplayState(hasTemperature: true, fanCount: 2, isEnabled: true, isActive: false) == .problem)
precondition(ControlDisplayState(hasTemperature: true, fanCount: 2, isEnabled: true, isActive: true) == .active)

let history = TemperatureHistory.appending(
    70,
    fanPercentage: 50,
    at: 100_000,
    to: [
        TemperatureSample(timestamp: 10_000, temperature: 40, fanPercentage: 10),
        TemperatureSample(timestamp: 99_950, temperature: 60, fanPercentage: 40)
    ],
    interval: 60,
    retention: 86_400
)
precondition(history == [TemperatureSample(timestamp: 99_950, temperature: 60, fanPercentage: 40)])
precondition(TemperatureHistory.appending(
    70,
    fanPercentage: 50,
    at: 100_010,
    to: history
) == history + [TemperatureSample(timestamp: 100_010, temperature: 70, fanPercentage: 50)])

let oldHistory = try! JSONDecoder().decode(
    [TemperatureSample].self,
    from: Data(#"[{"timestamp":100,"temperature":55}]"#.utf8)
)
precondition(oldHistory == [TemperatureSample(timestamp: 100, temperature: 55)])

var wakeRecovery = WakeRecovery()
let oldPoll = wakeRecovery.beginPoll()!
precondition(!oldPoll)
wakeRecovery.prepareForSleep(wasEnabled: true)
precondition(wakeRecovery.didWake())
precondition(wakeRecovery.beginPoll() == nil)
precondition(!wakeRecovery.finishPoll(isWakePoll: oldPoll, hasTemperature: true))
let firstWakePoll = wakeRecovery.beginPoll()!
precondition(firstWakePoll)
precondition(!wakeRecovery.finishPoll(isWakePoll: firstWakePoll, hasTemperature: false))
let retryWakePoll = wakeRecovery.beginPoll()!
precondition(retryWakePoll)
precondition(wakeRecovery.finishPoll(isWakePoll: retryWakePoll, hasTemperature: true))
wakeRecovery.prepareForSleep(wasEnabled: false)
precondition(!wakeRecovery.didWake())

for (requested, temperature, fans, helper) in [
    (false, true, true, true),
    (true, false, true, true),
    (true, true, false, true),
    (true, true, true, false),
    (true, true, true, true)
] {
    var launchRecovery = LaunchRecovery(requested: requested)
    precondition(launchRecovery.finishFirstPoll(
        hasTemperature: temperature,
        hasSupportedFans: fans,
        helperIsCurrent: helper
    ) == (requested && temperature && fans && helper))
    precondition(!launchRecovery.finishFirstPoll(
        hasTemperature: true,
        hasSupportedFans: true,
        helperIsCurrent: true
    ))
}

print("FanCurve checks passed")
