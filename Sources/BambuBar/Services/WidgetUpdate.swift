import Darwin
import Foundation
import WidgetKit

/// After an update, desktop widgets keep showing what the old version drew until WidgetKit asks for a new
/// timeline, and macOS may keep the old widget extension running for a while. The first launch of a new build
/// stops that process and reloads every timeline, so placed widgets switch to the new design without being
/// removed and added again. (The widget kind and its configuration intent never change, or placed widgets
/// would lose their settings.)
@MainActor
enum WidgetUpdate {
    private static let key = "widgetsRefreshedForBuild"

    static func refreshIfUpdated() {
        guard !LaunchContext.isDeveloperRun else { return }
        let build = currentBuild
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        UserDefaults.standard.set(build, forKey: key)
        stopOldExtensions()
        // WidgetKit relaunches the extension from the new bundle when it next needs it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Version, build and when the executable was written, so reinstalling the same version counts too.
    private static var currentBuild: String {
        let written = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return "\(AppInfo.version)-\(AppInfo.build)-\(written)"
    }

    /// Terminates running copies of Bambu Bar's widget extension (only ours, found by path).
    private static func stopOldExtensions() {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(max(0, found))) where pid > 0 && pid != getpid() {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if String(cString: path).contains("/BambuBarWidget.appex/") { kill(pid, SIGTERM) }
        }
    }
}
