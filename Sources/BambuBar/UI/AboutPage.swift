import AppKit
import SwiftUI

/// About the app: version details for bug reports, how it works, privacy and credits.
struct AboutPage: View {
    @State private var copied = false
    private var updates: UpdateChecker { .shared }

    private var updateLine: String {
        switch updates.state {
        case .available(let release): return "\(release.version) is available"
        case .upToDate: return "Up to date"
        case .checking: return "Checking…"
        case .failed: return "Couldn’t check"
        case .idle: return updates.lastChecked == nil ? "Not checked yet" : "Up to date"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bambu Bar").font(.system(size: 30, weight: .bold))
                    Text("Version \(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
                    Text("Your Bambu Lab printer, one click away in the menu bar.")
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                    if let release = updates.available {
                        Button { updates.download(release) } label: {
                            Label("Get Bambu Bar \(release.version)", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accentDeep)
                        .help("Opens the \(release.version) release on GitHub")
                        .padding(.top, 6)
                    }
                }
            }
            .padding(.bottom, 4)

            section("This copy") {
                DetailRow(title: "Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                DetailRow(title: "System", value: "\(AppInfo.system) · \(AppInfo.architecture)")
                DetailRow(title: "License", value: "MIT, free and open source")
                HStack {
                    Text("Updates").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(updateLine).font(.system(size: 12)).foregroundStyle(updates.available == nil ? .secondary : Palette.accent)
                    if let release = updates.available {
                        Button("Download") { updates.download(release) }.controlSize(.small)
                    } else if updates.state == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check Now") { Task { await updates.check() } }.controlSize(.small)
                    }
                }
                HStack {
                    Text("For bug reports").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Version Info", action: copy)
                        .controlSize(.small)
                }
            }

            section("How it works") {
                paragraph("Bambu Bar connects straight to your printer on the local network, the same way Bambu Studio does in LAN mode: an encrypted MQTT connection on port 8883, signed in with the printer's access code. The printer's certificate is checked against Bambu Lab's own certificate authority.")
                paragraph("The printer streams its status about once a second. Bambu Bar shows it in the menu bar, keeps a short history of your prints, and shares a snapshot with its widget through a private container on this Mac.")
            }

            section("Privacy") {
                paragraph("No account, no cloud, no analytics. Bambu Bar talks to your printer on your network, and the access code is stored in your keychain.")
                paragraph("Its only other request is the optional daily update check, which reads this project's latest release on GitHub and sends nothing about you or your printers. Turn it off in Settings → Updates.")
            }

            section("Links") {
                link("Project on GitHub", symbol: "chevron.left.forwardslash.chevron.right", AppInfo.project)
                link("Release Notes", symbol: "doc.text", AppInfo.project.appendingPathComponent("releases/tag/v\(AppInfo.version)"))
                link("Report an Issue", symbol: "exclamationmark.bubble", AppInfo.project.appendingPathComponent("issues/new"))
            }

            section("Credits") {
                paragraph("Protocol details and the English HMS error texts come from the open-source ha-bambulab project (MIT), with thanks to Bambuddy and bambu-cli for documenting the newer printers. What each model can do (chamber sensor, fans, heated chamber, nozzles, build volume) follows the printer profiles Bambu Lab publishes with Bambu Studio.")
                paragraph("The printer models were built for this project in Blender. They are visual approximations, not manufacturer CAD.")
                paragraph("Bambu Lab, Bambu Studio and P2S are trademarks of Bambu Lab. Bambu Bar is an independent project, not affiliated with or endorsed by Bambu Lab.")
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 10) { content() }
                .panel(radius: 16, padding: 16)
        }
    }

    private func link(_ title: String, symbol: String, _ url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
            }
            .font(.system(size: 12.5))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Palette.accent)
        .help(url.absoluteString)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppInfo.summary, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

enum AppInfo {
    private static let info = Bundle.main.infoDictionary ?? [:]
    static let version = info["CFBundleShortVersionString"] as? String ?? "dev"
    static let build = info["CFBundleVersion"] as? String ?? "dev"
    static let system: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
    }()
    static let architecture: String = {
        #if arch(arm64)
            "Apple Silicon"
        #else
            "Intel"
        #endif
    }()
    static let project = URL(string: "https://github.com/\(UpdateChecker.repository)")!
    static var summary: String { "Bambu Bar \(version) (\(build)) · \(system) · \(architecture)" }
}
