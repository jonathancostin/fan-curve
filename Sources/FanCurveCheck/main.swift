import FanCurveCore

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

let fan = FanRange(id: 0, minimumRPM: 2_000, maximumRPM: 8_000)
precondition(fan.rpm(at: -1) == 2_000)
precondition(fan.rpm(at: 50) == 5_000)
precondition(fan.rpm(at: 101) == 8_000)

precondition(FanSmoothing.next(current: 20, target: 80) == 25)
precondition(FanSmoothing.next(current: 80, target: 20) == 78)
precondition(FanSmoothing.next(current: 50, target: 53) == 53)
precondition(FanSmoothing.next(current: 50, target: 52) == 50)

let history = TemperatureHistory.appending(
    70,
    at: 100_000,
    to: [
        TemperatureSample(timestamp: 10_000, temperature: 40),
        TemperatureSample(timestamp: 99_950, temperature: 60)
    ],
    interval: 60,
    retention: 86_400
)
precondition(history == [TemperatureSample(timestamp: 99_950, temperature: 60)])
precondition(TemperatureHistory.appending(70, at: 100_010, to: history).count == 2)

print("FanCurve checks passed")
