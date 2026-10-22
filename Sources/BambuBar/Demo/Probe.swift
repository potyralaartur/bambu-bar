import AppKit
import Foundation

/// `--probe <host> <serial> <access-code> [seconds]`: connects like the app does, prints what happens and a
/// summary of the first full report, then exits. For diagnosing a printer from Terminal without the UI.
/// Add `--insecure-tls` for the local test broker. `--dry start|stop <ams id>` also sends a drying command after the
/// first report and keeps logging, to see whether the firmware takes it.
@MainActor
enum Probe {
    static var arguments: (host: String, serial: String, code: String, seconds: Double)? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--probe"), i + 3 < a.count else { return nil }
        let seconds = i + 4 < a.count ? Double(a[i + 4]) ?? 20 : 20
        return (a[i + 1], a[i + 2], a[i + 3], seconds)
    }

    private static var connection: PrinterConnection?

    /// `--dry start 0`: (start, AMS id).
    static var dryTest: (start: Bool, unit: Int)? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--dry"), i + 2 < a.count, let unit = Int(a[i + 2]) else { return nil }
        return (a[i + 1] == "start", unit)
    }

    static func run(host: String, serial: String, code: String, seconds: Double) {
        let started = Date()
        func log(_ text: String) {
            print(String(format: "[%5.1fs] ", Date().timeIntervalSince(started)) + text)
            fflush(stdout)
        }
        let connection = PrinterConnection()
        self.connection = connection
        var reports = 0
        connection.onPhase = { phase in
            log("phase: \(phase)")
            if phase != .connecting, let verdict = BambuTrust.lastVerdict { log("certificate: \(verdict)") }
        }
        connection.onAck = { command, ok, reason in log("ack: \(command) \(ok ? "ok" : "failed") \(reason ?? "")") }
        connection.onStatus = { status, doc in
            reports += 1
            if reports == 1 || reports % 10 == 0 {
                log("status #\(reports): \(summary(status))")
            }
            if reports == 1, let test = dryTest {
                if test.start, let unit = status.ams.first(where: { $0.id == test.unit }) {
                    let plan = DryingPlan.recommended(for: unit, rotateSpools: false)
                    log("sending drying start to AMS \(test.unit): \(plan.filament) \(plan.summary) (\(plan.source))")
                    connection.startDrying(plan, unit: test.unit)
                } else if !test.start {
                    log("sending drying stop to AMS \(test.unit)")
                    connection.stopDrying(unit: test.unit)
                } else {
                    log("no AMS with id \(test.unit); ids: \(status.ams.map(\.id))")
                }
            }
        }
        log("connecting to \(host) as \(serial)")
        connection.start(PrinterConfig(host: host, serial: serial, name: serial, modelCode: ""), accessCode: code,
                         insecure: CommandLine.arguments.contains("--insecure-tls"))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            log("done: \(reports) status updates")
            connection.stop()
            exit(reports > 0 ? 0 : 1)
        }
    }

    private static func summary(_ s: PrinterStatus) -> String {
        var lines = [
            "\(s.state.title), stage \(s.stageID.map(String.init) ?? "-") (\(s.stageText ?? "-"))",
            "job \"\(s.jobName)\" \(s.progress)% layer \(s.layer)/\(s.totalLayers), \(s.remainingMinutes) min left",
            "nozzle \(s.nozzle.current)/\(s.nozzle.target) bed \(s.bed.current)/\(s.bed.target) chamber \(s.chamber.map { "\($0)" } ?? "-")",
            "fans part \(s.partFan ?? -1)% aux \(s.auxFan ?? -1)% exhaust \(s.exhaustFan ?? -1)%  speed \(s.speed.title)",
            "light \(s.chamberLightOn.map { $0 ? "on" : "off" } ?? "-") door \(s.doorOpen.map { $0 ? "open" : "closed" } ?? "-") wifi \(s.wifiSignal ?? 0) dBm",
            "remote drying: \(s.supportsRemoteDrying.map { $0 ? "yes" : "no" } ?? "not reported")",
            "controls locked: \(s.controlsLocked)  firmware \(s.firmware ?? "-")  nozzle \(s.nozzleDiameter ?? 0) \(s.nozzleType ?? "-")",
        ]
        for unit in s.ams {
            let spools = unit.spools.map { "\($0.label) \($0.isLoaded ? "\($0.material) #\($0.color.prefix(6)) \($0.remainText)" : "empty")" }
            lines.append("\(unit.title) \(unit.humidity.map { "\($0)%RH" } ?? "") \(unit.temperature.map { "\($0)°" } ?? ""): " + spools.joined(separator: ", "))
            if unit.kind.canDry {
                let tags = unit.spools.compactMap { s in s.dryingTemp.map { "\(s.label) \($0)°/\(s.dryingHours ?? 0)h" } }
                lines.append("  dryer: \(unit.dryingPhase?.title ?? "phase not reported"), \(unit.dryingMinutesLeft) min left, "
                    + "setting \(unit.dryingSetting.map { "\($0.filament) \($0.temperature)°/\($0.hours)h" } ?? "-"), "
                    + "blockers \(unit.dryingBlockers.map { $0.map { "\($0.rawValue)" }.joined(separator: ",") } ?? "-"), "
                    + "tags \(tags.isEmpty ? "-" : tags.joined(separator: " "))")
            }
        }
        if let ext = s.externalSpool { lines.append("external: \(ext.isLoaded ? "\(ext.material) #\(ext.color.prefix(6))" : "empty")") }
        lines.append("active spool: \(s.activeSpoolID.map(String.init) ?? "-")")
        for issue in s.issues { lines.append("issue \(issue.id) [\(issue.severity.title)]: \(issue.message)") }
        return lines.joined(separator: "\n         ")
    }
}
