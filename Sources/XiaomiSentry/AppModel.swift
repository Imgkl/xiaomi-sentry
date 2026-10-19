import AppKit
import Foundation
import SentryCore

/// A go2rtc stream. `name` is the device name go2rtc reported when it created the stream,
/// otherwise the stream name exactly as the server lists it.
struct Camera: Equatable, Identifiable {
    let stream: String
    let name: String
    var id: String { stream }
}

struct Position: Equatable {
    let pan: Int
    let tilt: Int
}

struct SetupDraft {
    var host = ""
    var port = "1984" // go2rtc's default API port
    var user = ""
    var password = ""
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var cameras: [Camera] = []
    @Published private(set) var selected = 0
    @Published private(set) var playerState: PlayerState = .idle
    @Published private(set) var position: Position?
    @Published private(set) var toast: String?
    @Published private(set) var camerasLoaded = false
    @Published private(set) var notice: String?
    @Published var showingSetup = false
    @Published var draft = SetupDraft()
    @Published private(set) var setupError: String?
    @Published private(set) var busy = false
    /// Xiaomi cloud region used by "Add from Xiaomi".
    @Published var region = AppSettings.region {
        didSet { AppSettings.region = region }
    }

    let player = StreamPlayer()
    /// Asks the menu bar controller to show the panel.
    var requestOpen: (() -> Void)?

    /// How long the stream stays up after the panel closes, so a quick reopen is instant.
    /// While it is up, frames still flow from the camera to go2rtc and to the Mac.
    private let linger: Duration = .seconds(60)

    private var client: Go2RTCClient?
    private var config: ServerConfig?
    private var panelOpen = false
    private var lingerTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// Stream the player was last asked to open, so repeated requests do not restart it.
    private var activeStream: String?
    /// Set while Retry or Reconnect reloads the list, so opening the panel does not connect as well.
    private var reconnecting = false
    private var toastToken = 0
    private var panInFlight = false
    private var queuedOperation: Int?
    private var heldOperation: Int?

    init() {
        player.onState = { [weak self] state in self?.playerChanged(state) }
    }

    var hasConfig: Bool { config != nil }
    var camera: Camera? { cameras.indices.contains(selected) ? cameras[selected] : nil }

    /// Engraving under the screen: the camera name from the server, as is.
    var brandText: String { camera?.name.uppercased() ?? "" }

    /// Position of the selected camera, shown on the round switch chip.
    var cameraNumber: String { String(selected + 1) }

    var readout: String {
        guard let position else { return "PAN --  TILT --" }
        return "PAN \(position.pan)  TILT \(position.tilt)"
    }

    // MARK: Lifecycle

    func start() {
        guard let saved = AppSettings.load() else {
            showingSetup = true
            return
        }
        use(saved)
        ensureCamerasLoaded()
    }

    func panelDidOpen() {
        panelOpen = true
        lingerTask?.cancel()
        lingerTask = nil
        guard client != nil, !showingSetup, !reconnecting else { return }
        if camerasLoaded { connect() } else { ensureCamerasLoaded() }
    }

    /// One camera list request at a time. When it lands, open the stream if the panel is up.
    private func ensureCamerasLoaded() {
        guard loadTask == nil else { return }
        loadTask = Task {
            let loaded = await loadCameras()
            loadTask = nil
            if loaded, panelOpen { connect() }
        }
    }

    func panelDidClose() {
        panelOpen = false
        heldOperation = nil
        lingerTask?.cancel()
        lingerTask = Task { [weak self, linger] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled, let self, !self.panelOpen else { return }
            self.player.stop()
            self.activeStream = nil
        }
    }

    // MARK: Cameras

    /// Fetches the stream list. It does not open a stream; callers decide that.
    @discardableResult
    func loadCameras() async -> Bool {
        guard let client else { return false }
        do {
            let names = try await client.streamNames()
            guard client === self.client else { return false }   // settings changed meanwhile
            apply(names)
            return true
        } catch Go2RTCError.unauthorized {
            guard client === self.client else { return false }
            openSetup(error: "go2rtc refused this user or password.")
        } catch {
            guard client === self.client else { return false }
            if playerState == .live || playerState == .connecting {
                showToast(message(for: error))
            } else {
                playerState = .offline(message(for: error))
            }
        }
        return false
    }

    private func apply(_ names: [String]) {
        let known = AppSettings.displayNames
        cameras = names.map { Camera(stream: $0, name: known[$0] ?? $0) }
        camerasLoaded = true
        notice = cameras.isEmpty ? "go2rtc has no camera streams yet." : nil
        // Open the camera picked last. If it is gone from the server, fall back to the first.
        if let last = AppSettings.lastStream, let i = cameras.firstIndex(where: { $0.stream == last }) {
            selected = i
        } else {
            selected = 0
        }
        if let camera { AppSettings.lastStream = camera.stream }
    }

    func select(_ index: Int) {
        guard cameras.indices.contains(index), index != selected || playerState != .live else { return }
        selected = index
        position = nil
        heldOperation = nil
        queuedOperation = nil
        AppSettings.lastStream = cameras[index].stream
        connect()
    }

    func nextCamera() {
        guard !cameras.isEmpty else { return }
        select((selected + 1) % cameras.count)
    }

    /// Opens the selected camera. Opening the panel, loading the list and picking a camera can
    /// all ask at once, and every restart is a cold start for the camera that go2rtc has to redial,
    /// so a stream that is already coming up or live is kept unless `force` is set (Retry).
    func connect(force: Bool = false) {
        guard let client, let camera else { return }
        if !force, activeStream == camera.stream, playerState == .connecting || playerState == .live { return }
        activeStream = camera.stream
        playerState = .connecting
        player.start(client: client, stream: camera.stream)
    }

    func reconnect() {
        reconnecting = true
        Task {
            if await loadCameras() { connect(force: true) }
            reconnecting = false
        }
    }

    /// Creates one stream per camera in the Xiaomi account that go2rtc is logged in to.
    /// This writes the streams into go2rtc's yaml, so it runs only on a button press.
    func addCamerasFromXiaomi() async {
        guard let client, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let accounts = try await client.xiaomiAccounts()
            guard !accounts.isEmpty else {
                notice = "Log in to Xiaomi once in the go2rtc web page."
                return
            }
            var names = AppSettings.displayNames
            for account in accounts {
                for source in try await client.xiaomiSources(account: account, region: region.rawValue) {
                    let stream = Self.streamName(source.name)
                    try await client.addStream(name: stream, source: source.url)
                    names[stream] = source.name
                }
            }
            AppSettings.displayNames = names
            if await loadCameras() { connect() }
        } catch {
            notice = message(for: error)
        }
    }

    // MARK: Pan

    /// One step, for a tap or for keyboard and accessibility actions.
    func press(_ operation: Int) {
        guard canMove() else { return }
        // go2rtc runs commands one at a time and each waits for the camera. Keep one tap queued.
        if panInFlight {
            queuedOperation = operation
            return
        }
        send(operation, announce: true)
    }

    /// Press and hold: steps keep going, each sent when the previous one returns, until release.
    func beginHold(_ operation: Int) {
        guard canMove() else { return }
        heldOperation = operation
        if panInFlight {
            // Released before the current step returns? Then this still sends one step.
            queuedOperation = operation
        } else {
            queuedOperation = nil
            send(operation, announce: true)
        }
    }

    func endHold() {
        heldOperation = nil
    }

    private func canMove() -> Bool {
        guard client != nil, camera != nil else { return false }
        switch playerState {
        case .live:
            return true
        case .connecting, .idle:
            showToast("Wait for the picture")
        default:
            showToast("No live stream to move")
        }
        return false
    }

    private func send(_ operation: Int, announce: Bool) {
        guard let client, let camera else { return }
        let stream = camera.stream
        panInFlight = true
        if announce { showToast(Self.label(operation)) }
        Task {
            var keepGoing = true
            do {
                let reply = try await client.pan(stream: stream, operation: operation)
                if self.camera?.stream != stream {
                    keepGoing = false   // camera switched while the step was out; ignore its reply
                } else if reply.noReply {
                    showToast("No reply from the camera")
                } else if let ret = reply.ret, ret != 0 {
                    showToast("The camera refused the move")
                    keepGoing = false
                } else if let angle = reply.angle, let elevation = reply.elevation {
                    let next = Position(pan: angle, tilt: elevation)
                    if next == position {
                        // The camera reports no limits; an unchanged position means the end stop.
                        showToast("End of travel")
                        keepGoing = false
                    }
                    position = next
                }
            } catch Go2RTCError.conflict {
                showToast("Live view is not open on go2rtc")
                keepGoing = false
            } catch Go2RTCError.unauthorized {
                openSetup(error: "go2rtc refused this user or password.")
                keepGoing = false
            } catch Go2RTCError.notFound {
                showToast("go2rtc has no stream with this name")
                keepGoing = false
            } catch {
                showToast("Move failed")
                keepGoing = false
            }
            panInFlight = false

            if let held = heldOperation {
                guard keepGoing else {
                    heldOperation = nil
                    return
                }
                queuedOperation = nil
                // Short gap between steps so the camera and go2rtc are not flooded.
                try? await Task.sleep(for: .milliseconds(120))
                if heldOperation == held, !panInFlight { send(held, announce: false) }
                return
            }
            if let next = queuedOperation {
                queuedOperation = nil
                press(next)
            }
        }
    }

    static func label(_ operation: Int) -> String {
        ["", "Pan left", "Pan right", "Tilt up", "Tilt down"][max(0, min(operation, 4))]
    }

    // MARK: Setup

    func openSetup(error: String? = nil) {
        if let config {
            draft = SetupDraft(host: config.host, port: String(config.port), user: config.username,
                               password: config.password)
        }
        setupError = error
        showingSetup = true
        player.stop()
        requestOpen?()
    }

    func cancelSetup() {
        guard config != nil else { return }
        setupError = nil
        showingSetup = false
        connect()
    }

    func submitSetup() async {
        guard !busy else { return }
        // Accept a pasted URL: keep only the host.
        var host = draft.host.trimmingCharacters(in: .whitespaces)
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        guard !host.isEmpty, let port = Int(draft.port.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port) else {
            setupError = "Enter the server address and port."
            return
        }
        let candidate = ServerConfig(host: host, port: port,
                                     username: draft.user.trimmingCharacters(in: .whitespaces),
                                     password: draft.password)
        busy = true
        setupError = nil
        defer { busy = false }
        let test = Go2RTCClient(config: candidate)
        do {
            let names = try await test.streamNames()
            AppSettings.save(candidate)
            use(candidate, client: test)
            showingSetup = false
            apply(names)
            connect()
        } catch {
            test.invalidate()
            if case Go2RTCError.unauthorized = error {
                setupError = "go2rtc refused this user or password."
            } else if case Go2RTCError.unreachable = error {
                setupError = "Can't reach \(host):\(port). If macOS asked about Local Network access, allow it and try again."
            } else {
                setupError = message(for: error)
            }
        }
    }

    private func use(_ c: ServerConfig, client existing: Go2RTCClient? = nil) {
        player.stop()
        client?.invalidate()
        config = c
        client = existing ?? Go2RTCClient(config: c)
        camerasLoaded = false
        position = nil
        activeStream = nil
    }

    // MARK: State

    private func playerChanged(_ state: PlayerState) {
        playerState = state
        if state == .unauthorized { openSetup(error: "go2rtc refused this user or password.") }
    }

    func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toast = text
        Task {
            try? await Task.sleep(for: .milliseconds(1300))
            if token == toastToken { toast = nil }
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case Go2RTCError.unreachable:
            return "Can't reach go2rtc. Check that it runs and that Local Network access is on."
        case Go2RTCError.badAddress:
            return "Enter only the server address, like 192.168.1.5 or camera.local."
        case Go2RTCError.unauthorized:
            return "go2rtc refused this user or password."
        case Go2RTCError.server(let code, let body):
            return body.isEmpty ? "go2rtc answered HTTP \(code)." : body
        case Go2RTCError.notFound(let body):
            return body.isEmpty ? "Not found on go2rtc." : body
        default:
            return "Something went wrong talking to go2rtc."
        }
    }

    #if DEBUG
    /// Snapshot mode only: a still picture shown instead of the video layer.
    var demoPicture: NSImage?

    func debugInstall(cameras: [Camera], selected: Int, state: PlayerState, toast: String?, position: Position?) {
        self.cameras = cameras
        self.selected = selected
        camerasLoaded = true
        playerState = state
        self.toast = toast
        self.position = position
    }
    #endif

    /// Stream name for a discovered camera: "Front Door 2" becomes "front_door_2".
    static func streamName(_ name: String) -> String {
        let parts = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return parts.isEmpty ? "camera" : parts.joined(separator: "_")
    }
}
