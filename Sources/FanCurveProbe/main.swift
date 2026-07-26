import CryptoKit
import Darwin
import FanCurveCore
import Foundation
import StatsSMC

struct FanReport: Encodable {
    let id: Int
    let minimumRPM: Int
    let maximumRPM: Int
    let actualRPM: Double?
    let targetRPM: Double?
    let mode: String
}

struct SupportReport: Encodable {
    let schemaVersion = 1
    let model: String
    let chip: String
    let architecture: String
    let macOS: String
    let appVersion: String
    let sourceRevision: String?
    let smcKeyCount: Int
    let cpuTemperatureCelsius: Double?
    let cpuSensorKeys: [String]
    let fanControlSupported: Bool
    let fans: [FanReport]
    let helperInstalled: Bool
    let helperActive: Bool
    let bundledHelperSHA256: String?
    let installedHelperSHA256: String?
    let helperMatchesBundle: Bool?
}

private func systemValue(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: value)
}

private func fanMode(_ fanID: Int) -> HardwareFanMode? {
    #if arch(arm64)
    return MacHardware.appleFanMode(SMC.shared.getValue(SMC.shared.fanModeKey(fanID)))
    #else
    return MacHardware.intelFanMode(SMC.shared.getValue("FS! "), fanID: fanID)
    #endif
}

private func finiteSMCValue(_ key: String) -> Double? {
    guard let value = SMC.shared.getValue(key), value.isFinite else { return nil }
    return value
}

private func sha256(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func redirectStandardOutputToStandardError() -> Int32 {
    fflush(nil)
    let savedOutput = dup(STDOUT_FILENO)
    guard savedOutput >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
        if savedOutput >= 0 { close(savedOutput) }
        return -1
    }
    return savedOutput
}

private func restoreStandardOutput(_ savedOutput: Int32) -> Bool {
    fflush(nil)
    let restored = dup2(savedOutput, STDOUT_FILENO) >= 0
    close(savedOutput)
    return restored
}

let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let contentsURL = executableURL.deletingLastPathComponent().deletingLastPathComponent()
let info = (try? Data(contentsOf: contentsURL.appendingPathComponent("Info.plist")))
    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
    as? [String: Any]
let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "development"
let buildVersion = info?["CFBundleVersion"] as? String
let appVersion = buildVersion.map { "\(shortVersion) (\($0))" } ?? shortVersion
let bundledHelperHash = sha256(contentsURL.appendingPathComponent("Resources/FanCurveHelper"))
let installedHelperURL = URL(
    fileURLWithPath: HelperInstallation.helperPath
)
let installedHelperHash = sha256(installedHelperURL)

let savedOutput = redirectStandardOutputToStandardError()
guard savedOutput >= 0 else {
    FileHandle.standardError.write(Data("FanCurveProbe: could not protect JSON output\n".utf8))
    exit(1)
}
if CommandLine.arguments.dropFirst().contains("--check-output") {
    print("FanCurveProbe test diagnostic")
}
let availableKeys = Set(SMC.shared.getAllKeys())
let temperature = MacHardware.cpuTemperatureSnapshot(availableKeys: availableKeys) {
    SMC.shared.getValue($0)
}
let fans = MacHardware.fanRanges { SMC.shared.getValue($0) }
let fanReports = fans.map { fan in
    FanReport(
        id: fan.id,
        minimumRPM: fan.minimumRPM,
        maximumRPM: fan.maximumRPM,
        actualRPM: finiteSMCValue("F\(fan.id)Ac"),
        targetRPM: finiteSMCValue("F\(fan.id)Tg"),
        mode: fanMode(fan.id)?.rawValue ?? "unknown"
    )
}

#if arch(arm64)
let architecture = "arm64"
#else
let architecture = "x86_64"
#endif

let report = SupportReport(
    model: systemValue("hw.model"),
    chip: systemValue("machdep.cpu.brand_string"),
    architecture: architecture,
    macOS: ProcessInfo.processInfo.operatingSystemVersionString,
    appVersion: appVersion,
    sourceRevision: info?["FanCurveSourceRevision"] as? String,
    smcKeyCount: availableKeys.count,
    cpuTemperatureCelsius: temperature?.average,
    cpuSensorKeys: temperature?.sensorKeys ?? [],
    fanControlSupported: MacHardware.supportsFanControl(fans, readMode: fanMode),
    fans: fanReports,
    helperInstalled: HelperInstallation.isSecure(),
    helperActive: FileManager.default.fileExists(atPath: "/var/run/fancurve.active"),
    bundledHelperSHA256: bundledHelperHash,
    installedHelperSHA256: installedHelperHash,
    helperMatchesBundle: bundledHelperHash.flatMap { bundled in
        installedHelperHash.map { $0 == bundled }
    }
)
guard restoreStandardOutput(savedOutput) else {
    FileHandle.standardError.write(Data("FanCurveProbe: could not restore JSON output\n".utf8))
    exit(1)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
do {
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("FanCurveProbe: \(error.localizedDescription)\n".utf8))
    exit(1)
}
