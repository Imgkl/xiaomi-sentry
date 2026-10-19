#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `swift run XiaomiSentry --snapshot docs/screenshots` renders the real panel
/// to PNG files for the README. The screen shows a drawn, out-of-focus picture instead of a camera feed.
@MainActor
enum Snapshot {
    static func run(into directory: String) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let shots: [(String, ColorScheme, (AppModel) -> Void)] = [
            ("live-light", .light, { $0.debugShow(setup: false, state: .live, position: Position(pan: 31, tilt: 1)) }),
            ("live-dark", .dark, { $0.debugShow(setup: false, state: .live, position: Position(pan: 58, tilt: 12), camera: 1) }),
        ]
        for (name, scheme, configure) in shots {
            let model = AppModel()
            model.demoPicture = demoPicture()
            configure(model)
            guard let png = render(PanelRoot().environmentObject(model), scheme: scheme) else { continue }
            let file = url.appendingPathComponent("\(name).png")
            try? png.write(to: file)
            print(file.path)
        }
    }

    /// Renders through a real NSHostingView in an offscreen window, so AppKit text fields draw too.
    private static func render<V: View>(_ view: V, scheme: ColorScheme) -> Data? {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.intrinsicContentSize
        let margin: CGFloat = 24
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: size.width + margin * 2, height: size.height + margin * 2))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = (scheme == .dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.90, alpha: 1)).cgColor
        host.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        canvas.addSubview(host)

        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = canvas
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        canvas.layoutSubtreeIfNeeded()

        // Core Animation render keeps the SwiftUI shapes and the AppKit fields in one pass.
        let scale: CGFloat = 2
        guard let layer = canvas.layer,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width * scale),
                                         pixelsHigh: Int(canvas.bounds.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        context.cgContext.scaleBy(x: scale, y: scale)
        layer.render(in: context.cgContext)
        window.orderOut(nil)
        return rep.representation(using: .png, properties: [:])
    }

    /// A dark, out-of-focus picture drawn in code: soft light spots on a night gradient.
    static func demoPicture() -> NSImage {
        NSImage(size: NSSize(width: 1280, height: 720), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let space = CGColorSpaceCreateDeviceRGB()
            let sky = CGGradient(colorsSpace: space, colors: [
                CGColor(red: 0.07, green: 0.10, blue: 0.16, alpha: 1),
                CGColor(red: 0.13, green: 0.12, blue: 0.16, alpha: 1),
                CGColor(red: 0.20, green: 0.14, blue: 0.12, alpha: 1),
            ] as CFArray, locations: [0, 0.6, 1])!
            ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: rect.height), options: [])
            let spots: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (0.18, 0.62, 170, 1.00, 0.70, 0.38), (0.36, 0.48, 120, 0.98, 0.84, 0.60),
                (0.55, 0.70, 210, 0.95, 0.55, 0.30), (0.72, 0.40, 140, 0.55, 0.70, 0.95),
                (0.86, 0.66, 180, 1.00, 0.78, 0.50), (0.08, 0.30, 110, 0.60, 0.80, 0.90),
            ]
            for (x, y, r, red, green, blue) in spots {
                let center = CGPoint(x: x * rect.width, y: y * rect.height)
                let spot = CGGradient(colorsSpace: space, colors: [
                    CGColor(red: red, green: green, blue: blue, alpha: 0.55),
                    CGColor(red: red, green: green, blue: blue, alpha: 0),
                ] as CFArray, locations: [0, 1])!
                ctx.drawRadialGradient(spot, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: r, options: [])
            }
            return true
        }
    }
}

extension AppModel {
    func debugShow(setup: Bool, state: PlayerState, position: Position? = nil, camera: Int = 0) {
        debugInstall(cameras: [Camera(stream: "front_door", name: "front_door"),
                               Camera(stream: "garage", name: "garage")],
                     selected: camera, state: state, toast: nil, position: position)
        showingSetup = setup
        if setup {
            draft = SetupDraft(host: "192.168.1.20", port: "1984", user: "admin", password: "example-password")
        }
    }
}
#endif
