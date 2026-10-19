import AVFoundation
import SwiftUI

// Handheld design: a small plastic-style body, an inset screen with the live picture,
// and two hardware keys. The left key pans, the right key tilts.

enum Metrics {
    static let deviceWidth: CGFloat = 320
    /// Concentric corners: everything inside the body uses the body radius minus the inset,
    /// and the keys are capsules of exactly that radius, so every gap stays 14 pt around the curves.
    static let inset: CGFloat = 14
    static let bodyRadius: CGFloat = 41
    static let innerRadius: CGFloat = bodyRadius - inset
    static let keyHeight: CGFloat = innerRadius * 2
    static let screenSize = CGSize(width: deviceWidth - inset * 2, height: 201)
    /// Camera name engraved between screen and keys in the live view.
    static let engravingHeight: CGFloat = 19
    static let engravingGap: CGFloat = 8
    /// Setup has no engraving: its screen takes that space, keeping the body the same size,
    /// and the gap above the keys becomes the regular inset.
    static let setupScreenHeight = screenSize.height + engravingHeight + engravingGap - inset
    /// Content padding inside the screen, clear of its 27 pt corners.
    static let screenPadding: CGFloat = 18
    /// Transparent edge around the body. The system shadow is drawn outside the window, so none is needed.
    static let shadowMargin: CGFloat = 0
}

struct PanelRoot: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HandheldDevice()
            .padding(Metrics.shadowMargin)
            .fixedSize()
    }
}

struct HandheldDevice: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(spacing: 0) {
            Group {
                if model.showingSetup { SetupScreen() } else { LiveScreen() }
            }
            // The screen is dark in both themes, so its controls always use dark-mode colors.
            .environment(\.colorScheme, .dark)
            .frame(width: Metrics.screenSize.width,
                   height: model.showingSetup ? Metrics.setupScreenHeight : Metrics.screenSize.height)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous))
            .overlay(ScreenBezel())

            if !model.showingSetup {
                HStack {
                    Spacer()
                    Text(model.brandText)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(dark ? Color.white.opacity(0.55) : Color.black.opacity(0.60))
                }
                .padding(.horizontal, 10)
                .frame(height: Metrics.engravingHeight, alignment: .bottom)
            }

            Group {
                if model.showingSetup { SetupKeys(dark: dark) } else { PanKeys(dark: dark) }
            }
            .padding(.top, model.showingSetup ? Metrics.inset : Metrics.engravingGap)
        }
        .padding(Metrics.inset)
        .frame(width: Metrics.deviceWidth)
        .background(DeviceBody(dark: dark))
    }
}

// MARK: - Body and bezel

struct DeviceBody: View {
    let dark: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.bodyRadius, style: .continuous)
        shape
            .fill(LinearGradient(
                // Body sits a step darker than the keys so they read as raised (contrast ~1.4:1).
                colors: dark
                    ? [Color(red: 0.149, green: 0.153, blue: 0.165), Color(red: 0.094, green: 0.098, blue: 0.106)]
                    : [Color(red: 0.894, green: 0.894, blue: 0.878), Color(red: 0.808, green: 0.808, blue: 0.788)],
                startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(
                colors: [Color.white.opacity(dark ? 0.10 : 0.95), Color.white.opacity(0)],
                startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.22)), lineWidth: 1))
            .overlay(shape.stroke(Color.black.opacity(dark ? 0.6 : 0.07), lineWidth: 0.5))
        // No drawn shadow: the panel window casts the system shadow from this outline.
    }
}

/// Inner shadow and hairline that make the screen look set into the body.
struct ScreenBezel: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
        ZStack {
            shape.stroke(Color.black.opacity(0.65), lineWidth: 5).blur(radius: 4).offset(y: 2).mask(shape)
            shape.strokeBorder(Color.black.opacity(0.55), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Live screen

struct LiveScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color(red: 0.047, green: 0.051, blue: 0.055)
            #if DEBUG
            if let demo = model.demoPicture {
                // Fills the screen without widening the layout, like the video layer.
                Color.clear
                    .overlay { Image(nsImage: demo).resizable().scaledToFill() }
                    .clipped()
            } else {
                VideoSurface(layer: model.player.displayLayer)
            }
            #else
            VideoSurface(layer: model.player.displayLayer)
            #endif
            RadialGradient(colors: [.clear, .black.opacity(0.42)], center: .center, startRadius: 100, endRadius: 200)
                .allowsHitTesting(false)

            // Under the chips, so switching camera works while a camera is offline or connecting.
            StateOverlay()

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    ClockChip(state: model.playerState)
                    Spacer()
                    if let camera = model.camera {
                        Button { model.nextCamera() } label: {
                            Text(model.cameraNumber)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(white: 0.95))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.white.opacity(0.14)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Switch camera: \(camera.name)")
                        .accessibilityLabel("Switch camera")
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    DotMatrixText(text: model.readout, dot: 1.6, gap: 0.5, color: Color(white: 0.95).opacity(0.88))
                        .opacity(model.playerState == .live ? 1 : 0)
                    Spacer()
                    if model.cameras.count > 1 { PageDots() }
                }
            }
            .padding(12)

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.62)))
                        .padding(.bottom, 30)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
    }
}

struct ClockChip: View {
    let state: PlayerState
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            HStack(spacing: 7) {
                Text(Self.format.string(from: context.date))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.95))
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .background(Circle().fill(dotColor.opacity(state == .live ? 0.25 : 0)).frame(width: 13, height: 13))
                    .opacity(state == .connecting && Int(context.date.timeIntervalSince1970 * 2) % 2 == 0 ? 0.25 : 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.12)))
        }
    }

    private var dotColor: Color {
        switch state {
        case .live: return Color(red: 1, green: 0.54, blue: 0.12)
        case .connecting: return Color(red: 0.95, green: 0.76, blue: 0.31)
        default: return Color(white: 0.55)
        }
    }
}

struct PageDots: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.cameras.enumerated()), id: \.element.id) { index, camera in
                Button { model.select(index) } label: {
                    Circle()
                        .fill(Color.white.opacity(index == model.selected ? 1 : 0.35))
                        .frame(width: 7, height: 7)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(camera.name)
            }
        }
        .padding(.bottom, 1)
    }
}

struct StateOverlay: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.camerasLoaded && model.cameras.isEmpty {
            panel(dim: 0.88) {
                DotMatrixText(text: "NO CAMERAS", dot: 2.1, gap: 0.6)
                caption(model.notice ?? "go2rtc has no camera streams yet.")
                HStack(spacing: 10) {
                    Menu {
                        Picker("Xiaomi region", selection: $model.region) {
                            ForEach(AppSettings.Region.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        pillLabel(model.region.title + " ▾")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Xiaomi account region")
                    pill(model.busy ? "Adding…" : "Add from Xiaomi") { Task { await model.addCamerasFromXiaomi() } }
                }
            }
        } else {
            switch model.playerState {
            case .live:
                EmptyView()
            case .idle, .connecting:
                panel(dim: 0.55) {
                    DotMatrixText(text: "CONNECTING", dot: 2.1, gap: 0.6)
                    caption("Opening the stream")
                }
            case .offline(let reason):
                panel(dim: 0.88) {
                    fitted(model.camera?.name.uppercased() ?? "CAMERA")
                    DotMatrixText(text: "OFFLINE", dot: 2.1, gap: 0.6)
                    HStack(spacing: 10) {
                        pill("Retry") { model.reconnect() }
                        // The raw go2rtc error stays off the screen; copy it when needed.
                        pill("Copy error") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reason, forType: .string)
                            model.showToast("Error copied")
                        }
                    }
                    .padding(.top, 4)
                }
            case .unauthorized:
                panel(dim: 0.88) {
                    DotMatrixText(text: "LOCKED", dot: 2.1, gap: 0.6)
                    caption("go2rtc refused the login.")
                }
            }
        }
    }

    /// Dot-matrix line that shrinks its dots so any server name fits the screen width.
    private func fitted(_ text: String) -> some View {
        let cell = min(2.7, 240 / (CGFloat(max(text.count, 1)) * 6))
        return DotMatrixText(text: text, dot: cell * 0.78, gap: cell * 0.22)
    }

    private func panel<Content: View>(dim: Double, @ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(dim)
            VStack(spacing: 9) { content() }
                .padding(.horizontal, 22)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color(white: 0.72))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(title) }
            .buttonStyle(.plain)
    }

    private func pillLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(white: 0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.10)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.18)))
            .contentShape(Capsule(style: .continuous))
    }
}

// MARK: - Video

/// Hosts the player's AVSampleBufferDisplayLayer. The layer outlives the panel,
/// so reopening shows the last picture at once.
struct VideoSurface: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> VideoHostView { VideoHostView(videoLayer: layer) }
    func updateNSView(_ view: VideoHostView, context: Context) {}
}

final class VideoHostView: NSView {
    private let videoLayer: AVSampleBufferDisplayLayer

    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        let host = CALayer()
        host.cornerRadius = Metrics.innerRadius
        host.cornerCurve = .continuous
        host.masksToBounds = true
        layer = host
        wantsLayer = true
        videoLayer.removeFromSuperlayer()
        host.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Keys

struct PanKeys: View {
    let dark: Bool

    var body: some View {
        HStack(spacing: 12) {
            KeyPill(dark: dark, left: (1, "chevron.left"), right: (2, "chevron.right"))
            KeyPill(dark: dark, left: (3, "chevron.up"), right: (4, "chevron.down"))
        }
    }
}

struct KeyPill: View {
    @EnvironmentObject var model: AppModel
    let dark: Bool
    let left: (op: Int, symbol: String)
    let right: (op: Int, symbol: String)

    var body: some View {
        HStack(spacing: 0) {
            half(left)
            Rectangle()
                .fill(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.14))
                .frame(width: 1, height: 22)
            half(right)
        }
        .frame(height: Metrics.keyHeight)
        .background(KeySurface(dark: dark))
        .clipShape(Capsule(style: .continuous))
        .modifier(KeyShadow(dark: dark))
    }

    private func half(_ key: (op: Int, symbol: String)) -> some View {
        HoldKey(symbol: key.symbol, dark: dark,
                onPress: { model.beginHold(key.op) }, onRelease: { model.endHold() })
            .accessibilityElement()
            .accessibilityLabel(AppModel.label(key.op))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.press(key.op) }
    }
}

/// Key half that steps while held: press starts the hold, release (anywhere) ends it.
/// A quick tap therefore sends exactly one step.
struct HoldKey: View {
    let symbol: String
    let dark: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(dark ? Color(white: 0.92) : Color(white: 0.18))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pressed ? Color.black.opacity(dark ? 0.28 : 0.08) : Color.clear)
            .offset(y: pressed ? 1 : 0)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        onRelease()
                    }
            )
    }
}

struct KeySurface: View {
    let dark: Bool

    var body: some View {
        Capsule(style: .continuous)
            .fill(LinearGradient(
                colors: dark
                    ? [Color(red: 0.271, green: 0.275, blue: 0.290), Color(red: 0.208, green: 0.212, blue: 0.227)]
                    : [Color.white, Color(red: 0.945, green: 0.945, blue: 0.933)],
                startPoint: .top, endPoint: .bottom))
            .overlay(Capsule(style: .continuous).strokeBorder(LinearGradient(
                colors: [Color.white.opacity(dark ? 0.10 : 1), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.black.opacity(dark ? 0.7 : 0.22), lineWidth: 0.75))
    }
}

/// Contact shadow plus a soft drop so the keys sit above the body.
struct KeyShadow: ViewModifier {
    let dark: Bool

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(dark ? 0.45 : 0.20), radius: 1, x: 0, y: 1.5)
            .shadow(color: .black.opacity(dark ? 0.30 : 0.10), radius: 4, x: 0, y: 3)
    }
}

struct KeyPressStyle: ButtonStyle {
    let dark: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(dark ? Color(white: 0.92) : Color(white: 0.18))
            .background(configuration.isPressed ? Color.black.opacity(dark ? 0.28 : 0.08) : Color.clear)
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}

// MARK: - Setup

struct SetupScreen: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focus: Field?
    private enum Field { case host, port, user, password }

    var body: some View {
        ZStack {
            Color(red: 0.047, green: 0.051, blue: 0.055)
            // Header at the top, fields centred below it, an error line at the bottom only when needed.
            // Every edge uses the same screen padding; fields sit on a 10 pt rhythm.
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    DotMatrixText(text: "SET UP", dot: 1.9, gap: 0.55)
                    Spacer()
                    Text("go2rtc server")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.68))
                }
                Spacer(minLength: 12)
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        field("Server address", text: $model.draft.host).focused($focus, equals: .host)
                        field("Port", text: $model.draft.port).focused($focus, equals: .port).frame(width: 72)
                    }
                    field("API user", text: $model.draft.user).focused($focus, equals: .user)
                    SecureField("", text: $model.draft.password)
                        .modifier(FieldStyle(placeholder: "API password", isEmpty: model.draft.password.isEmpty))
                        .focused($focus, equals: .password)
                        .onSubmit { Task { await model.submitSetup() } }
                }
                Spacer(minLength: 10)
                if let error = model.setupError {
                    Text(error)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color(red: 1, green: 0.65, blue: 0.42))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Metrics.screenPadding)
        }
        .onAppear { focus = model.draft.user.isEmpty ? .user : .password }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        TextField("", text: text)
            .modifier(FieldStyle(placeholder: label, isEmpty: text.wrappedValue.isEmpty))
            .onSubmit { Task { await model.submitSetup() } }
    }
}

/// Field on the dark screen. The placeholder is drawn here, because the system placeholder
/// color follows the panel theme and turns dark grey on this dark field in the light theme.
struct FieldStyle: ViewModifier {
    let placeholder: String
    let isEmpty: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(white: 0.95))
            .tint(Color(red: 1, green: 0.54, blue: 0.12))
            .overlay(alignment: .leading) {
                if isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.66))
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.14)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.24)))
    }
}

struct SetupKeys: View {
    @EnvironmentObject var model: AppModel
    let dark: Bool

    var body: some View {
        HStack(spacing: 12) {
            wide(model.busy ? "Connecting…" : "Connect") { Task { await model.submitSetup() } }
            if model.hasConfig {
                wide("Cancel") { model.cancelSetup() }
            }
        }
    }

    private func wide(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyPressStyle(dark: dark))
        .frame(height: Metrics.keyHeight)
        .background(KeySurface(dark: dark))
        .clipShape(Capsule(style: .continuous))
        .modifier(KeyShadow(dark: dark))
        .disabled(model.busy)
    }
}
