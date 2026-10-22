import SwiftUI

/// The dryer of one AMS 2 Pro or AMS HT: what it's doing, a start/stop button, and the smart drying rules.
struct DryingPanel: View {
    @Environment(PrinterStore.self) private var store
    var session: PrinterSession
    var unit: AMSUnit

    var body: some View {
        let status = session.status
        let remote = status.map { SmartDrying.canDryRemotely($0) } ?? false
        let drying = session.isDrying(unit)
        let rules = store.drying.settings(session.id, unit: unit.id)
        let plan = DryingPlan.recommended(for: unit, rotateSpools: rules.rotateSpools)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: drying ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(drying ? Palette.bed : .secondary)
                    .symbolEffect(.pulse, options: .repeating, isActive: drying)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(drying: drying)).font(.system(size: 13, weight: .semibold))
                    Text(detail(drying: drying, plan: plan))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if drying {
                    Button("Stop Drying") { store.stopDrying(unit, on: session) }
                        .disabled(!remote)
                } else {
                    Button("Start Drying") { store.startDrying(unit, on: session) }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accentDeep)
                        .disabled(!remote || !(unit.dryingBlockers ?? []).isEmpty)
                }
            }
            if !drying, let blockers = unit.dryingBlockers, !blockers.isEmpty {
                ForEach(Array(Set(blockers.map(\.message))).sorted(), id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.paused)
                }
            }
            if !remote {
                Text("This printer's firmware doesn't take drying commands over the network yet, so drying has to be started on its screen. Bambu Bar still shows the time left.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            SmartDryingRules(session: session, unit: unit, enabled: remote)
        }
        .panel(radius: 16, padding: 14, tint: drying ? Palette.bed : nil)
    }

    private func headline(drying: Bool) -> String {
        if drying {
            let phase = unit.dryingPhase.map { $0 == .off ? "Drying" : $0.title } ?? "Drying"
            let left = unit.dryingMinutesLeft > 0 ? " · \(Format.duration(minutes: unit.dryingMinutesLeft)) left" : ""
            return phase + left
        }
        if unit.dryingPhase == .cooling { return "Cooling down" }
        return unit.humidity.map { "Not drying · \($0)% humidity" } ?? "Not drying"
    }

    private func detail(drying: Bool, plan: DryingPlan) -> String {
        if drying {
            var parts: [String] = []
            if let s = unit.dryingSetting, s.temperature > 0 {
                parts.append("\(s.filament.isEmpty ? "" : s.filament + " at ")\(s.temperature)°")
            }
            if let t = unit.temperature { parts.append("now \(Format.temperature(t))") }
            if let h = unit.humidity { parts.append("\(h)% humidity") }
            if store.drying.isSmartCycle(session.id, unit: unit.id) { parts.append("started by smart drying") }
            return parts.isEmpty ? "The AMS is heating." : parts.joined(separator: " · ")
        }
        return "Dries at \(plan.summary), from the \(plan.source)."
    }
}

/// Smart drying: start above one humidity, stop at another, optionally only in set hours.
private struct SmartDryingRules: View {
    @Environment(PrinterStore.self) private var store
    var session: PrinterSession
    var unit: AMSUnit
    var enabled: Bool

    var body: some View {
        let rules = store.drying.settings(session.id, unit: unit.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart drying").font(.system(size: 12.5, weight: .semibold))
                    Text("Keeps the humidity in range on its own while Bambu Bar is running.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: binding(\.enabled)).toggleStyle(.switch).labelsHidden().tint(Palette.accentDeep)
            }
            if rules.enabled {
                stepper("Start when humidity is above", value: binding(\.startAbove), range: 2...80)
                stepper("Stop once it falls to", value: binding(\.stopAt), range: 1...(rules.startAbove - 1))
                Text("The AMS reads low while it's warm and settles a few points higher afterwards, so stop a little below the level you want.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Only dry between").font(.system(size: 12.5))
                    Spacer()
                    if rules.limitHours {
                        timePicker(\.windowStart)
                        Text("and").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        timePicker(\.windowEnd)
                    }
                    Toggle("", isOn: binding(\.limitHours)).toggleStyle(.switch).labelsHidden().tint(Palette.accentDeep)
                }
                if rules.limitHours {
                    WeekdayPicker(selection: binding(\.weekdays))
                    if rules.windowEnd < rules.windowStart {
                        Text("Runs overnight, into the next morning.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                toggle("Also while printing", binding(\.whilePrinting))
                toggle("Turn the spools", binding(\.rotateSpools))
                Text("Turning helps the spools dry evenly. Pull the filament back out of the feeders first, or the printer won't start.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = store.drying.notes[SmartDrying.key(session.id, unit.id)] {
                    Label(note, systemImage: "info.circle")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func binding<T>(_ path: WritableKeyPath<SmartDryingSettings, T>) -> Binding<T> {
        Binding(
            get: { store.drying.settings(session.id, unit: unit.id)[keyPath: path] },
            set: { value in
                var rules = store.drying.settings(session.id, unit: unit.id)
                rules[keyPath: path] = value
                store.drying.update(session.id, unit: unit.id, rules)
                store.drying.evaluate(session)
            }
        )
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer()
            Text("\(value.wrappedValue)%").font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
            Stepper("", value: value, in: range).labelsHidden()
        }
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().tint(Palette.accentDeep)
        }
    }

    /// A clock-time field for minutes after midnight.
    private func timePicker(_ path: WritableKeyPath<SmartDryingSettings, Int>) -> some View {
        let minutes = binding(path)
        let date = Binding<Date>(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) },
            set: { new in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: new)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
        return DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .frame(width: 70)
    }
}

/// Seven day chips in the order the person's calendar starts its week.
private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let days = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: 6) {
            Spacer()
            ForEach(days, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(symbols[day - 1])
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(on ? Palette.accentDeep : Color.primary.opacity(0.08)))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(calendar.weekdaySymbols[day - 1])
            }
        }
    }
}
