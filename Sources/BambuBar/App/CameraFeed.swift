import AppKit
import CoreMedia
import Observation

/// One printer's camera, shared by every view that shows it.
///
/// The stream runs while at least one `CameraSurfaceView` is on screen (a hidden window, a collapsed
/// preview or a closed panel don't count), and for the whole of a print so opening the panel shows it at once.
/// Otherwise it stops a few seconds after the last surface goes, so switching from the panel to the window
/// doesn't reconnect. Frames fan out to every surface; a surface that appears mid-stream
/// is caught up from the last keyframe.
@MainActor
@Observable
final class CameraFeed {
    enum State: Equatable {
        case idle
        case connecting
        case live
        /// Nothing to try right now (printer offline, Liveview off, demo).
        case unavailable(String)
        /// The last attempt failed; `retrying` says whether another one is scheduled.
        case failed(String, retrying: Bool)
    }

    private(set) var state: State = .idle
    /// "H.264 · 1920×1080", once the stream has started.
    private(set) var detail: String?
    /// Width over height of the picture; 16:9 until the stream says otherwise.
    private(set) var aspectRatio: CGFloat = 16 / 9

    @ObservationIgnored private weak var session: PrinterSession?
    @ObservationIgnored private var client: CameraClient?
    @ObservationIgnored private let surfaces = NSHashTable<CameraSurfaceView>.weakObjects()
    /// The stream since its last keyframe, to bring a new surface up to date.
    @ObservationIgnored private var sinceKeyframe: [CMSampleBuffer] = []
    @ObservationIgnored private var lastImage: CGImage?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var retry: Timer?
    @ObservationIgnored private var idleStop: Timer?

    init(session: PrinterSession) {
        self.session = session
    }

    var isRunning: Bool { client != nil }

    private var hasViewers: Bool { surfaces.allObjects.contains { $0.isOnScreen } }

    /// A print is under way: keep the stream warm even with nothing on screen.
    private var keepsWarm: Bool { session?.status?.state.isActive == true && availability() == nil }

    private var wanted: Bool { hasViewers || keepsWarm }

    // MARK: - Surfaces

    func attach(_ surface: CameraSurfaceView) {
        surfaces.add(surface)
        surface.feed = self
        if let lastImage { surface.show(lastImage) }
        for (index, sample) in sinceKeyframe.enumerated() { surface.show(sample, keyframe: index == 0) }
        viewersChanged()
    }

    func detach(_ surface: CameraSurfaceView) {
        surfaces.remove(surface)
        if surface.feed === self { surface.feed = nil }
        viewersChanged()
    }

    /// A surface appeared or disappeared on screen, or a print started or ended.
    func viewersChanged() {
        if wanted {
            idleStop?.invalidate()
            idleStop = nil
            if client == nil && retry == nil { connect() }
        } else if client != nil || retry != nil, idleStop == nil {
            idleStop = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.idleStop = nil
                    if !self.wanted { self.stop() }
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Something the stream depends on changed (connection, Liveview setting, print state): reconsider.
    func update() {
        if let reason = availability() {
            if client != nil || retry != nil { stop() }
            state = .unavailable(reason)
            return
        }
        switch state {
        case .unavailable, .failed(_, retrying: false):
            retry?.invalidate()
            retry = nil
            attempt = 0
            if wanted { connect() } else { state = .idle }
        default:
            viewersChanged()
        }
    }

    func tryAgain() {
        stop()
        attempt = 0
        if wanted { connect() }
    }

    /// Reconnects if running, e.g. after the printer moved to a new address.
    func restart() {
        guard client != nil || retry != nil else { return }
        stop()
        connect()
    }

    func stop() {
        retry?.invalidate()
        retry = nil
        idleStop?.invalidate()
        idleStop = nil
        client?.onEvent = nil
        client?.stop()
        client = nil
        sinceKeyframe = []
        lastImage = nil
        for surface in surfaces.allObjects { surface.clear() }
        state = .idle
        detail = nil
    }

    /// Why the camera can't be tried now, if it can't.
    private func availability() -> String? {
        guard let session else { return "No printer." }
        if session.isDemo { return "The demo printer has no camera." }
        guard session.isOnline else { return "The camera starts when the printer is connected." }
        if session.cameraTransport == .rtsps && session.status?.liveViewEnabled == false {
            return "Turn on LAN Only Liveview on the printer (Settings → Network) to see the camera here."
        }
        return nil
    }

    private func connect() {
        retry = nil
        if let reason = availability() {
            state = .unavailable(reason)
            return
        }
        guard let session, let code = session.cameraAccessCode else {
            state = .unavailable("The access code isn't available.")
            return
        }
        let client = makeCameraClient(CameraConfig(host: session.config.host, serial: session.config.serial, accessCode: code,
                                                   transport: session.cameraTransport, insecure: session.allowsInsecureTLS))
        client.onEvent = { [weak self, weak client] event in
            MainActor.assumeIsolated {
                guard let self, let client, client === self.client else { return }
                self.handle(event)
            }
        }
        self.client = client
        if case .live = state {} else { state = .connecting }
        client.start()
    }

    private func handle(_ event: CameraEvent) {
        switch event {
        case .started(let description, let size):
            detail = description
            if size.width > 0 && size.height > 0 { aspectRatio = size.width / size.height }
        case .video(let sample, let keyframe):
            if keyframe {
                sinceKeyframe = [sample]
            } else if !sinceKeyframe.isEmpty && sinceKeyframe.count < 300 {
                sinceKeyframe.append(sample)
            }
            for surface in surfaces.allObjects { surface.show(sample, keyframe: keyframe) }
            becameLive()
        case .image(let image):
            lastImage = image
            for surface in surfaces.allObjects { surface.show(image) }
            becameLive()
        case .failed(let failure):
            client = nil
            sinceKeyframe = []
            if failure.isPermanent {
                state = .failed(failure.message, retrying: false)
                return
            }
            let delays: [TimeInterval] = [1, 3, 6, 12, 30]
            let delay = delays[min(attempt, delays.count - 1)]
            attempt += 1
            // A stream that was fine and dropped once reconnects quietly.
            if !(state == .live && attempt == 1) { state = .failed(failure.message, retrying: true) }
            retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.connect() }
            }
        }
    }

    private func becameLive() {
        guard state != .live else { return }
        state = .live
        attempt = 0
    }
}
