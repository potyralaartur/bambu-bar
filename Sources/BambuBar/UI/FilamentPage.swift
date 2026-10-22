import SwiftUI

/// Every loaded spool, large, with material, colour, what's left and the AMS climate.
struct FilamentPage: View {
    @Environment(PrinterStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Filament", subtitle: subtitle)
            if let status = store.status, store.isOnline {
                if status.ams.isEmpty && status.externalSpool == nil {
                    empty("No AMS connected", detail: "Spools loaded in an AMS or on the external holder appear here.")
                }
                ForEach(status.ams) { unit in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(unit.title).font(.system(size: 16, weight: .semibold))
                            Spacer()
                            climate(unit)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(unit.spools) { SpoolCard(spool: $0, active: $0.id == status.activeSpoolID && status.state.isActive) }
                        }
                        if unit.kind.canDry, let session = store.current {
                            DryingPanel(session: session, unit: unit)
                        }
                    }
                }
                if let ext = status.externalSpool {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("External spool").font(.system(size: 16, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            SpoolCard(spool: ext, active: ext.id == status.activeSpoolID && status.state.isActive)
                        }
                    }
                }
            } else {
                empty(store.isConfigured ? "Printer offline" : "No printer set up",
                      detail: store.isConfigured ? "Filament appears once Bambu Bar is connected." : "Set up your printer on the Printer page.")
            }
        }
    }

    private var subtitle: String {
        guard let s = store.status else { return "Spools in your AMS and on the external holder" }
        let loaded = s.allSpools.filter(\.isLoaded).count
        if let active = s.activeSpool, s.state.isActive { return "\(loaded) loaded · printing with \(active.label) \(active.displayName)" }
        return "\(loaded) spool\(loaded == 1 ? "" : "s") loaded"
    }

    @ViewBuilder
    private func climate(_ unit: AMSUnit) -> some View {
        HStack(spacing: 14) {
            if unit.isDrying {
                Label(unit.dryingMinutesLeft > 0 ? "Drying · \(Format.duration(minutes: unit.dryingMinutesLeft)) left" : "Drying",
                      systemImage: "sun.max.fill")
                    .foregroundStyle(Palette.bed)
            }
            if let h = unit.humidity {
                Label("\(h)% humidity", systemImage: "humidity.fill").foregroundStyle(h > 40 ? Palette.paused : .secondary)
            } else if let level = unit.humidityLevel {
                Label("Humidity \(level) of 5", systemImage: "humidity.fill").foregroundStyle(level >= 4 ? Palette.paused : .secondary)
            }
            if let t = unit.temperature {
                Label(Format.temperature(t), systemImage: "thermometer.medium").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .labelStyle(TightLabelStyle())
    }

    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "circle.circle").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .panel()
    }
}

struct SpoolCard: View {
    var spool: Spool
    var active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                SpoolSwatch(spool: spool, active: active, size: 58)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(spool.label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    if active {
                        Text("In use").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.accent)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(spool.isLoaded ? spool.displayName : "Empty slot")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(spool.isLoaded ? .primary : .secondary)
                    .lineLimit(1)
                Text(spool.isLoaded ? detail : "Load a spool to see it here")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if spool.isLoaded {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Remaining").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                        Text(spool.remain.map { "\($0)%" } ?? "Unknown").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    }
                    FilamentProgressBar(progress: Double(spool.remain ?? 0) / 100,
                                        tint: Color(bambuHex: spool.color).map { bambuLuminance(spool.color) > 0.88 ? Color.secondary : $0 } ?? .secondary,
                                        height: 5)
                        .opacity(spool.remain == nil ? 0.4 : 1)
                }
            }
        }
        .panel(radius: 18, padding: 14, tint: active ? Palette.accent : nil)
        .overlay {
            if active {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.accent.opacity(0.6), lineWidth: 1.2)
            }
        }
    }

    private var detail: String {
        var parts = [spool.material]
        parts.append("#" + String(spool.color.prefix(6)))
        parts.append(spool.isBambu ? "Bambu RFID" : "Third-party")
        return parts.joined(separator: " · ")
    }
}
