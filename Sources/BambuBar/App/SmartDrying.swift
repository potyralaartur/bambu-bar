import Foundation
import Observation

/// One drying cycle as the AMS is told to run it.
struct DryingPlan: Equatable {
    /// Material type sent with the command ("PLA").
    var filament: String
    var temperature: Int
    var hours: Int
    var rotateSpools: Bool
    /// The AMS stops cooling the spools once it's below this.
    var coolingTemperature = 50
    /// Where the numbers came from: "PLA Basic tag", "typical for PETG"…
    var source: String

    /// "55° for 8h".
    var summary: String { "\(temperature)° for \(hours)h" }

    /// The cycle for whatever is in the unit. Spools with an RFID tag bring their own recipe; others fall back to
    /// the usual numbers for their material. The most heat-sensitive spool sets the temperature, the longest the time.
    static func recommended(for unit: AMSUnit, rotateSpools: Bool) -> DryingPlan {
        struct Recipe { var material: String; var temp: Int; var hours: Int; var source: String }
        let recipes = unit.spools.filter(\.isLoaded).compactMap { spool -> Recipe? in
            if let temp = spool.dryingTemp, let hours = spool.dryingHours {
                return Recipe(material: spool.material, temp: temp, hours: hours, source: "\(spool.displayName) tag")
            }
            guard !spool.material.isEmpty else { return nil }
            let typical = typicalRecipe(spool.material)
            return Recipe(material: spool.material, temp: typical.temp, hours: typical.hours, source: "typical for \(spool.material)")
        }
        let range = unit.kind.dryingTemps
        guard let coolest = recipes.min(by: { $0.temp < $1.temp }) else {
            // Nothing loaded: repeat the last cycle, else a gentle default that suits every material.
            if let last = unit.dryingSetting, last.temperature > 0, last.hours > 0 {
                return DryingPlan(filament: last.filament, temperature: clamp(last.temperature, range), hours: last.hours,
                                  rotateSpools: rotateSpools, source: "last cycle")
            }
            return DryingPlan(filament: "PLA", temperature: clamp(50, range), hours: 8, rotateSpools: rotateSpools, source: "default")
        }
        let hours = recipes.map(\.hours).max() ?? coolest.hours
        let mixed = Set(recipes.map(\.temp)).count > 1
        return DryingPlan(filament: coolest.material, temperature: clamp(coolest.temp, range), hours: max(1, min(24, hours)),
                          rotateSpools: rotateSpools,
                          source: mixed ? "\(coolest.source), the most heat-sensitive spool" : coolest.source)
    }

    /// AMS 2 Pro / AMS HT numbers from Bambu's filament pages, for spools without a tag.
    private static func typicalRecipe(_ material: String) -> (temp: Int, hours: Int) {
        let m = material.uppercased()
        if m.hasPrefix("PLA") { return (55, 8) }
        if m.hasPrefix("TPU") || m.hasPrefix("PVA") || m.hasPrefix("BVOH") { return (65, 8) }
        if m.hasPrefix("PETG") || m.hasPrefix("PCTG") || m.hasPrefix("HIPS") { return (65, 8) }
        if m.hasPrefix("PA") || m.hasPrefix("PPA") || m.hasPrefix("PPS") { return (85, 12) }
        if m.hasPrefix("ABS") || m.hasPrefix("ASA") || m.hasPrefix("PC") || m.hasPrefix("PET") { return (80, 8) }
        return (55, 8)
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { max(range.lowerBound, min(range.upperBound, value)) }
}

/// The smart drying rules for one AMS unit.
struct SmartDryingSettings: Codable, Equatable {
    var enabled = false
    /// Start once the humidity stays above this (percent).
    var startAbove = 25
    /// Stop a smart cycle once the humidity falls to this. The AMS reads low while it's warm and the air
    /// settles a few points higher afterwards, so this sits below the level you actually want.
    var stopAt = 10
    /// Only start (and keep running) inside the hours below.
    var limitHours = false
    /// Minutes after midnight. An end before the start runs overnight.
    var windowStart = 9 * 60
    var windowEnd = 21 * 60
    /// `Calendar` weekdays, 1 = Sunday.
    var weekdays: Set<Int> = Set(1...7)
    var whilePrinting = false
    /// Turn the spools during drying. Only works with the filament pulled back out of the feeders.
    var rotateSpools = false

    func isInWindow(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard limitHours else { return true }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let weekday = parts.weekday ?? 1
        if windowStart == windowEnd { return weekdays.contains(weekday) }
        if windowStart < windowEnd { return weekdays.contains(weekday) && minute >= windowStart && minute < windowEnd }
        // Overnight: the evening part belongs to today, the early-morning part to the day before.
        if minute >= windowStart { return weekdays.contains(weekday) }
        let yesterday = weekday == 1 ? 7 : weekday - 1
        return minute < windowEnd && weekdays.contains(yesterday)
    }

    /// "09:00–21:00", "every day" etc. for status lines.
    var windowText: String {
        func time(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        return "\(time(windowStart))–\(time(windowEnd))"
    }
}

/// Runs smart drying: watches each heated AMS and starts or stops its dryer by the person's rules.
/// It acts only while Bambu Bar is running, and only ever stops cycles it started itself.
@MainActor
@Observable
final class SmartDrying {
    /// Keyed by `serial#amsID`.
    private(set) var settings: [String: SmartDryingSettings] = [:]
    /// What smart drying is waiting for or doing, per unit, for the Filament page.
    private(set) var notes: [String: String] = [:]

    /// A smart cycle started or ended: session, title, body.
    @ObservationIgnored var onEvent: ((PrinterSession, String, String) -> Void)?

    /// Cycles smart drying started, persisted so it can still stop them after a relaunch.
    @ObservationIgnored private var owned: Set<String> = []
    @ObservationIgnored private var aboveSince: [String: Date] = [:]
    @ObservationIgnored private var belowSince: [String: Date] = [:]
    @ObservationIgnored private var wasDrying: [String: Bool] = [:]
    @ObservationIgnored private var lastEnded: [String: Date] = [:]
    @ObservationIgnored private var lastCommand: [String: Date] = [:]
    @ObservationIgnored private var refusedUntil: [String: Date] = [:]
    /// The unit each printer was last sent a drying command for, to match the acknowledgement.
    @ObservationIgnored private var lastCommandUnit: [String: String] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// The humidity has to stay past a threshold this long, so opening the lid doesn't start a cycle.
    static let sustain: TimeInterval = 10 * 60
    /// After any cycle the air needs time to settle before the reading means anything again.
    static let rest: TimeInterval = 60 * 60
    private static let commandSpacing: TimeInterval = 3 * 60

    private enum Keys {
        static let settings = "smartDrying"
        static let owned = "smartDryingOwned"
        static let force = "forceRemoteDrying"
    }

    init() {
        if let data = defaults.data(forKey: Keys.settings),
           let saved = try? JSONDecoder().decode([String: SmartDryingSettings].self, from: data) {
            settings = saved
        }
        owned = Set(defaults.stringArray(forKey: Keys.owned) ?? [])
    }

    static func key(_ serial: String, _ unit: Int) -> String { "\(serial)#\(unit)" }

    func settings(_ serial: String, unit: Int) -> SmartDryingSettings { settings[Self.key(serial, unit)] ?? SmartDryingSettings() }

    func update(_ serial: String, unit: Int, _ new: SmartDryingSettings) {
        let key = Self.key(serial, unit)
        var new = new
        new.stopAt = min(new.stopAt, new.startAbove - 1)
        guard settings[key] != new else { return }
        settings[key] = new
        if !new.enabled { aboveSince[key] = nil; belowSince[key] = nil }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Keys.settings) }
    }

    func isSmartCycle(_ serial: String, unit: Int) -> Bool { owned.contains(Self.key(serial, unit)) }

    /// The firmware takes drying commands. `defaults write <bundle id> forceRemoteDrying -bool YES` tries anyway,
    /// for firmware that works but doesn't say so.
    static func canDryRemotely(_ status: PrinterStatus) -> Bool {
        status.supportsRemoteDrying == true || UserDefaults.standard.bool(forKey: Keys.force)
    }

    // MARK: - Commands

    func start(_ session: PrinterSession, unit: AMSUnit, smart: Bool) {
        let key = Self.key(session.id, unit.id)
        let plan = DryingPlan.recommended(for: unit, rotateSpools: settings(session.id, unit: unit.id).rotateSpools)
        session.startDrying(plan, unit: unit.id)
        lastCommand[key] = Date()
        lastCommandUnit[session.id] = key
        setOwned(key, smart)
    }

    func stop(_ session: PrinterSession, unit: AMSUnit) {
        let key = Self.key(session.id, unit.id)
        session.stopDrying(unit: unit.id)
        lastCommand[key] = Date()
        lastCommandUnit[session.id] = key
        setOwned(key, false)
    }

    /// The printer turned down the last drying command; don't keep retrying for a while.
    func refused(_ session: PrinterSession, reason: String?) {
        guard let key = lastCommandUnit[session.id] else { return }
        setOwned(key, false)
        refusedUntil[key] = Date().addingTimeInterval(30 * 60)
        notes[key] = "The printer refused the last drying command\(reason.map { ": \($0)" } ?? ""). Trying again in 30 minutes."
    }

    private func setOwned(_ key: String, _ on: Bool) {
        let before = owned
        if on { owned.insert(key) } else { owned.remove(key) }
        if owned != before { defaults.set(Array(owned), forKey: Keys.owned) }
    }

    // MARK: - Rules

    /// Checks every heated AMS of the printer. Called on each status update and once a minute.
    func evaluate(_ session: PrinterSession, now: Date = Date()) {
        guard let status = session.status, session.isOnline else { return }
        for unit in status.ams where unit.kind.canDry {
            let key = Self.key(session.id, unit.id)
            let drying = unit.isDrying
            if wasDrying[key] == true && !drying {
                lastEnded[key] = now
                belowSince[key] = nil
                if owned.contains(key) {
                    setOwned(key, false)
                    onEvent?(session, "Smart drying finished", "\(unit.title) is at \(unit.humidity.map { "\($0)%" } ?? "?") humidity.")
                }
            }
            if drying && wasDrying[key] != true { aboveSince[key] = nil }
            wasDrying[key] = drying

            let rules = settings(session.id, unit: unit.id)
            guard rules.enabled else { notes[key] = nil; continue }
            let note = decide(session, status: status, unit: unit, key: key, rules: rules, drying: drying, now: now)
            if notes[key] != note { notes[key] = note }
        }
    }

    private func decide(_ session: PrinterSession, status: PrinterStatus, unit: AMSUnit, key: String,
                        rules: SmartDryingSettings, drying: Bool, now: Date) -> String {
        guard Self.canDryRemotely(status) else {
            return "This printer's firmware doesn't take drying commands over the network."
        }
        if status.controlsLocked { return "Turn on LAN Only and Developer Mode on the printer so Bambu Bar can start drying." }
        guard let humidity = unit.humidity else { return "Waiting for a humidity reading from the AMS." }
        let recent = lastCommand[key].map { now.timeIntervalSince($0) < Self.commandSpacing } ?? false
        if let until = refusedUntil[key], until > now, let note = notes[key] { return note }

        if drying {
            guard owned.contains(key) else {
                return "Drying started outside smart drying. It's left to run its course."
            }
            if humidity <= rules.stopAt {
                let since = belowSince[key] ?? now
                belowSince[key] = since
                if now.timeIntervalSince(since) >= 5 * 60, !recent {
                    stop(session, unit: unit)
                    lastEnded[key] = now
                    onEvent?(session, "Smart drying finished", "\(unit.title) reached \(humidity)% humidity.")
                    return "Reached \(humidity)% humidity. Stopping."
                }
                return "At \(humidity)%. Stopping once it stays at \(rules.stopAt)% or below for 5 minutes."
            }
            belowSince[key] = nil
            if !rules.isInWindow(now), !recent {
                stop(session, unit: unit)
                lastEnded[key] = now
                onEvent?(session, "Smart drying paused", "\(unit.title) is outside its drying hours at \(humidity)% humidity.")
                return "Outside the drying hours. Stopping."
            }
            return "Drying until the humidity falls to \(rules.stopAt)% (now \(humidity)%)."
        }

        if owned.contains(key), let sent = lastCommand[key], now.timeIntervalSince(sent) >= Self.commandSpacing {
            // Started, yet the AMS never reported drying: the firmware ignored the command.
            setOwned(key, false)
            refusedUntil[key] = now.addingTimeInterval(30 * 60)
            let note = "The printer didn't start drying. Trying again in 30 minutes."
            notes[key] = note
            return note
        }
        guard humidity > rules.startAbove else {
            aboveSince[key] = nil
            return "Humidity is \(humidity)%. Drying starts above \(rules.startAbove)%."
        }
        let since = aboveSince[key] ?? now
        aboveSince[key] = since
        if !rules.isInWindow(now) {
            return "Humidity is \(humidity)%. Waiting for the drying hours (\(rules.windowText))."
        }
        if status.state.isActive && !rules.whilePrinting { return "Humidity is \(humidity)%. Waiting for the print to finish." }
        if let ended = lastEnded[key], now.timeIntervalSince(ended) < Self.rest {
            let left = Int((Self.rest - now.timeIntervalSince(ended)) / 60) + 1
            return "Humidity is \(humidity)%. Letting the air settle after the last cycle (\(left) min)."
        }
        if let blocker = unit.dryingBlockers?.first { return "Humidity is \(humidity)%, but: \(blocker.message)" }
        let waited = now.timeIntervalSince(since)
        guard waited >= Self.sustain else {
            let left = Int((Self.sustain - waited) / 60) + 1
            return "Humidity is \(humidity)%. Starting if it stays above \(rules.startAbove)% for \(left) more min."
        }
        guard !recent else { return "Starting…" }
        start(session, unit: unit, smart: true)
        let plan = DryingPlan.recommended(for: unit, rotateSpools: rules.rotateSpools)
        onEvent?(session, "Smart drying started", "\(unit.title) is at \(humidity)% humidity. Drying at \(plan.summary).")
        return "Starting at \(plan.summary)."
    }
}
