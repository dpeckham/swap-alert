import Cocoa
import Darwin

// MARK: - Swap monitor

/// Read `vm.swapusage` via sysctl and return the number of bytes currently
/// in use. The `xsw_usage` struct layout is:
///   xsu_total   u64
///   xsu_avail   u64
///   xsu_used    u64    <-- offset 16
///   xsu_pagesize u32
///   xsu_encrypted u32
/// We decode from a raw buffer to avoid relying on Swift bridging of the C struct.
func readSwapUsed() -> UInt64 {
    var size = 0
    guard sysctlbyname("vm.swapusage", nil, &size, nil, 0) == 0, size >= 24 else {
        return 0
    }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctlbyname("vm.swapusage", &buf, &size, nil, 0) == 0 else {
        return 0
    }
    return buf.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var swapTimer: Timer?
    private var pulseTimer: Timer?
    private var phase: Double = 0
    private var swapUsed: UInt64 = 0
    private var demoMode: Bool = CommandLine.arguments.contains("--demo")
    private var swapActive: Bool { demoMode || swapUsed > 0 }
    private var menuUsageItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = renderImage()
        statusItem.button?.toolTip = "swap-alert"

        // Menu
        let menu = NSMenu()
        menu.delegate = self
        menuUsageItem = NSMenuItem(title: "Swap: 0 MB", action: nil, keyEquivalent: "")
        menuUsageItem.isEnabled = false
        menu.addItem(menuUsageItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit swap-alert",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu

        // Initial swap check, then poll every 2 seconds.
        tickSwap()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tickSwap()
        }
        RunLoop.main.add(t, forMode: .common)
        swapTimer = t
    }

    private func tickSwap() {
        let wasActive = swapActive
        swapUsed = readSwapUsed()
        let nowActive = swapActive

        if nowActive != wasActive {
            restartPulseTimer()
        }
        if !nowActive {
            // Idle: redraw once so the dim dot reflects current state.
            statusItem.button?.image = renderImage()
        }
    }

    private func restartPulseTimer() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        guard swapActive else { return }
        phase = 0
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickPulse()
        }
        RunLoop.main.add(t, forMode: .common)
        pulseTimer = t
    }

    private func tickPulse() {
        // ~1 Hz pulse: full sine cycle in 30 frames at 30 fps.
        phase += (2 * .pi) / 30.0
        if phase > 2 * .pi { phase -= 2 * .pi }
        statusItem.button?.image = renderImage()
    }

    private func renderImage() -> NSImage {
        if swapActive {
            return renderPulsingOrb()
        }
        return renderIdleThumbsUp()
    }

    private func renderIdleThumbsUp() -> NSImage {
        // SF Symbol renders as a template image, so macOS auto-tints it to
        // match the menu bar (white in dark mode, black in light mode) just
        // like the system icons.
        let image = NSImage(
            systemSymbolName: "hand.thumbsup.fill",
            accessibilityDescription: "swap idle"
        ) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }

    private func renderPulsingOrb() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let phaseSnap = phase
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 4, dy: 4)
            let path = NSBezierPath(ovalIn: inset)
            let t = (sin(phaseSnap) + 1.0) / 2.0   // 0..1
            let alpha = 0.35 + 0.65 * t
            NSColor.systemRed.withAlphaComponent(alpha).setFill()
            path.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        let mb = Double(swapUsed) / (1024.0 * 1024.0)
        if mb >= 1024 {
            menuUsageItem.title = String(format: "Swap: %.2f GB", mb / 1024.0)
        } else {
            menuUsageItem.title = String(format: "Swap: %.0f MB", mb)
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
