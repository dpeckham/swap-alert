import Cocoa
import Darwin

// MARK: - Memory monitor

struct MemoryStats {
    var total: UInt64 = 0
    var memoryUsed: UInt64 = 0
    var appMemory: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cachedFiles: UInt64 = 0
    var swapUsed: UInt64 = 0
}

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

/// Read total physical memory via `hw.memsize`.
func readPhysicalMemory() -> UInt64 {
    var memSize: UInt64 = 0
    var memSizeLen = MemoryLayout<UInt64>.size
    guard sysctlbyname("hw.memsize", &memSize, &memSizeLen, nil, 0) == 0 else {
        return 0
    }
    return memSize
}

/// Gather memory stats analogous to Activity Monitor's menu bar widget.
///
/// Mapping (matches Activity Monitor terminology):
///   - App Memory   = (internal_page_count - purgeable_count) * page_size
///   - Wired Memory = wire_count * page_size
///   - Compressed   = compressor_page_count * page_size
///   - Cached Files = (external_page_count + purgeable_count) * page_size
///   - Memory Used  = App Memory + Wired + Compressed
func readMemoryStats() -> MemoryStats {
    var stats = MemoryStats()
    stats.total = readPhysicalMemory()
    stats.swapUsed = readSwapUsed()

    let pageSize = UInt64(vm_kernel_page_size)
    var vmStats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &vmStats) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return stats }

    let wired = UInt64(vmStats.wire_count) * pageSize
    let compressed = UInt64(vmStats.compressor_page_count) * pageSize
    let internalBytes = UInt64(vmStats.internal_page_count) * pageSize
    let purgeable = UInt64(vmStats.purgeable_count) * pageSize
    let external = UInt64(vmStats.external_page_count) * pageSize
    let appMemory = internalBytes > purgeable ? internalBytes - purgeable : 0

    stats.wired = wired
    stats.compressed = compressed
    stats.appMemory = appMemory
    stats.cachedFiles = external + purgeable
    stats.memoryUsed = wired + compressed + appMemory
    return stats
}

/// Format a byte count for display in the menu (matches Activity Monitor's
/// rough conventions: "0 bytes", "123 MB", "4.56 GB").
func formatBytes(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0 bytes" }
    let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
    if gb >= 1.0 {
        return String(format: "%.2f GB", gb)
    }
    let mb = Double(bytes) / (1024.0 * 1024.0)
    if mb >= 1.0 {
        return String(format: "%.0f MB", mb)
    }
    let kb = Double(bytes) / 1024.0
    if kb >= 1.0 {
        return String(format: "%.0f KB", kb)
    }
    return "\(bytes) bytes"
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var swapTimer: Timer?
    private var pulseTimer: Timer?
    private var phase: Double = 0
    private var memStats: MemoryStats = MemoryStats()
    private var demoMode: Bool = CommandLine.arguments.contains("--demo")
    private var swapActive: Bool { demoMode || memStats.swapUsed > 0 }

    private var memoryItem: NSMenuItem!
    private var memoryUsedItem: NSMenuItem!
    private var appMemoryItem: NSMenuItem!
    private var wiredMemoryItem: NSMenuItem!
    private var compressedItem: NSMenuItem!
    private var cachedFilesItem: NSMenuItem!
    private var swapUsedItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = renderImage()
        statusItem.button?.toolTip = "swap-alert"

        // Menu
        let menu = NSMenu()
        menu.delegate = self

        memoryItem = makeStatItem("Memory")
        memoryUsedItem = makeStatItem("Memory Used")
        appMemoryItem = makeStatItem("App Memory")
        wiredMemoryItem = makeStatItem("Wired Memory")
        compressedItem = makeStatItem("Compressed")
        cachedFilesItem = makeStatItem("Cached Files")
        swapUsedItem = makeStatItem("Swap Used")

        menu.addItem(memoryItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(memoryUsedItem)
        menu.addItem(appMemoryItem)
        menu.addItem(wiredMemoryItem)
        menu.addItem(compressedItem)
        menu.addItem(cachedFilesItem)
        menu.addItem(swapUsedItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit swap-alert",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu

        // Initial poll, then refresh every 2 seconds.
        tickSwap()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tickSwap()
        }
        RunLoop.main.add(t, forMode: .common)
        swapTimer = t
    }

    private func makeStatItem(_ label: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label): –", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.representedObject = label
        return item
    }

    private func tickSwap() {
        let wasActive = swapActive
        memStats = readMemoryStats()
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
        // Refresh stats now so the menu reflects the latest values rather than
        // whatever the 2-second poll happened to grab.
        memStats = readMemoryStats()

        setStat(memoryItem, label: "Memory", value: memStats.total)
        setStat(memoryUsedItem, label: "Memory Used", value: memStats.memoryUsed)
        setStat(appMemoryItem, label: "App Memory", value: memStats.appMemory)
        setStat(wiredMemoryItem, label: "Wired Memory", value: memStats.wired)
        setStat(compressedItem, label: "Compressed", value: memStats.compressed)
        setStat(cachedFilesItem, label: "Cached Files", value: memStats.cachedFiles)
        setStat(swapUsedItem, label: "Swap Used", value: memStats.swapUsed)
    }

    private func setStat(_ item: NSMenuItem, label: String, value: UInt64) {
        item.title = "\(label): \(formatBytes(value))"
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
