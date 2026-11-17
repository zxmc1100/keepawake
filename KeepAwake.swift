// KeepAwake: menu bar app that keeps the Mac running with the lid closed, rejoins known Wi-Fi
// and shows what the charger delivers. macOS itself does the locking. Everything is event-driven;
// see README.md.
import AppKit
import CoreWLAN
import IOKit
import IOKit.ps
import Network
import ServiceManagement
import UserNotifications
import os

let guardLabel = "com.zxmc.keepawake.guard"
let resetLabel = "com.zxmc.keepawake.reset"
let socketPath = "/var/run/\(guardLabel).sock"
let log = Logger(subsystem: "com.zxmc.keepawake", category: "app")

// Root side. launchd starts it per connection with the socket as stdin; `cat` blocks until the
// app closes the socket or dies for any reason (SIGKILL included), so it uses no CPU while armed
// and sleep can never stay disabled behind a dead app. Input only ever goes to /dev/null.
// PIPE is ignored because the app may already be gone when the ack is written. `cat` runs in the
// background because sh only runs a trap once its foreground command ends, and `wait` can be interrupted.
// A closed lid sleeps straight away, because clearing disablesleep alone doesn't trigger clamshell
// sleep. CausesSleep is No when docked to an external display, which must keep running.
// shortcut: guards aren't serialized, so a re-arm within the ~100 ms of a restore could lose to it; reopening the menu takes longer, serialize if anything but the menu ever arms.
let guardScript = """
trap '' PIPE
trap '/usr/bin/pmset -a disablesleep 0; exit 0' HUP INT TERM
/usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 || exit 1
echo ok
exec >/dev/null 2>&1
exec 3<&0
/bin/cat <&3 &
wait $!
/usr/bin/pmset -a disablesleep 0
[ "$(/usr/sbin/ioreg -r -k AppleClamshellState -d 1 | /usr/bin/grep -c 'AppleClamshell.*= Yes')" = 2 ] && /usr/bin/pmset sleepnow
exit 0
"""

func daemonPlists(uid: Int) -> [(label: String, data: Data)] {
    let guardJob: [String: Any] = [
        "Label": guardLabel,
        "ProgramArguments": ["/bin/sh", "-c", guardScript],
        "inetdCompatibility": ["Wait": false],
        "Sockets": ["Listener": ["SockPathName": socketPath, "SockPathMode": 0o600, "SockPathOwner": uid]],
    ]
    // A power cut skips the guard's restore, and SleepDisabled survives a reboot.
    let resetJob: [String: Any] = [
        "Label": resetLabel,
        "ProgramArguments": ["/usr/bin/pmset", "-a", "disablesleep", "0"],
        "RunAtLoad": true,
    ]
    return [guardJob, resetJob].map {
        ($0["Label"] as! String, try! PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0))
    }
}

func daemonPath(_ label: String) -> String { "/Library/LaunchDaemons/\(label).plist" }

// Shows the macOS password dialog; only needed the first time or after a plist changes.
func installHelperIfNeeded() -> Bool {
    let plists = daemonPlists(uid: Int(getuid()))
    // launchd removes the socket when the job is unloaded, so this also repairs a booted-out guard.
    let current = plists.allSatisfy { FileManager.default.contents(atPath: daemonPath($0.label)) == $0.data }
    if current && FileManager.default.fileExists(atPath: socketPath) { return true }
    // base64 because the XML is full of quotes, and no temp file a root process would read back.
    let writes = plists.map { plist -> String in
        let path = daemonPath(plist.label)
        return "/bin/echo \(plist.data.base64EncodedString()) | /usr/bin/base64 -D > \(path); "
            + "/usr/sbin/chown root:wheel \(path); /bin/chmod 644 \(path)"
    }.joined(separator: "; ")
    // The reset job is left for launchd to load at boot: loading it now would race the guard's disablesleep 1.
    let commands = "/bin/launchctl bootout system/\(guardLabel) 2>/dev/null || true; \(writes); "
        + "/bin/launchctl bootstrap system \(daemonPath(guardLabel))"
    let source = "do shell script \"set -e; \(commands)\" with prompt \"KeepAwake needs to install a small helper to control lid-closed sleep. You will only be asked once.\" with administrator privileges"
    var error: NSDictionary?
    _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { log.error("helper install failed: \(error, privacy: .public)") }
    return error == nil
}

// Existence check that also sees minimized, tabbed and other-Space windows, which
// .optionIncludingWindow misses. Costs about 0.15 ms.
func windowExists(_ id: CGWindowID) -> Bool {
    let ids = [UnsafeRawPointer(bitPattern: UInt(id))]
    let array = ids.withUnsafeBufferPointer { CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), 1, nil) }
    if let found = CGWindowListCreateDescriptionFromArray(array) as? [Any], !found.isEmpty { return true }
    // No answer about any window means WindowServer can't tell, not that the window closed.
    return (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [Any] ?? []).isEmpty
}

// Skips the invisible helper windows some apps keep at the normal window level.
func frontWindow(of pid: pid_t) -> CGWindowID? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.first {
        guard $0[kCGWindowOwnerPID as String] as? pid_t == pid, $0[kCGWindowLayer as String] as? Int == 0,
              let bounds = $0[kCGWindowBounds as String] as! CFDictionary?,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
        return rect.width >= 100 && rect.height >= 100
    }?[kCGWindowNumber as String] as? CGWindowID
}

// Private API, used on top of the public scan and skipped cleanly if Apple removes it.
enum AutoJoin {
    // static let so it only loads once needed; top-level globals in this file initialize at launch.
    static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi", RTLD_LAZY) != nil,
              let type = NSClassFromString("CWFInterface") as? NSObject.Type else { return nil }
        let client = type.init()
        _ = client.perform(NSSelectorFromString("activate"))
        return client
    }()

    // CWFAutoJoinParameters.trigger values, read from the class's own description.
    static let retry = 4
    static let instantHotspot = 61

    static func request(trigger: Int) {
        let selector = NSSelectorFromString("performAutoJoinWithParameters:error:")
        guard let client, client.responds(to: selector),
              let type = NSClassFromString("CWFAutoJoinParameters") as? NSObject.Type else { return }
        let parameters = type.init()
        guard parameters.responds(to: NSSelectorFromString("setTrigger:")) else { return }
        parameters.setValue(trigger, forKey: "trigger")
        _ = client.perform(selector, with: parameters, with: nil)
    }
}

// Instant Hotspot finds the iPhone over Bluetooth, so with it off the phone can never be reached.
// Slow (a process spawn), so never call this on the main thread.
func bluetoothIsOff() -> Bool {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPBluetoothDataType", "-json"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return isBluetoothOffReport(String(decoding: output, as: UTF8.self))
}

func isBluetoothOffReport(_ report: String) -> Bool { report.contains("\"controller_state\" : \"attrib_off\"") }

func retryDelay(attempt: Int) -> TimeInterval { min(300, 15 * pow(2, Double(attempt))) }

enum Tie {
    case window(CGWindowID, pid_t, String)
    case app(pid_t, String)

    var pid: pid_t {
        switch self {
        case .window(_, let pid, _), .app(let pid, _): return pid
        }
    }
    var summary: String {
        switch self {
        case .window(_, _, let name): return "until \(name) window closes"
        case .app(_, let name): return "until \(name) quits"
        }
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let defaults = UserDefaults.standard

    private var guardFD: Int32 = -1
    private var guardSource: DispatchSourceRead?
    private var awakeSince: Date?
    private var tie: Tie?
    private var tieTimer: Timer?
    private var problem: String? { didSet { updateIcon() } }

    private var pathMonitor: NWPathMonitor?
    private var online = true
    private var wifiAttempt = 0
    private var wifiRetry: DispatchWorkItem?
    private var bluetoothOff = false

    private var activity: NSObjectProtocol?

    private var charger = ChargerReading(battery: [:], adapter: nil, thermal: .nominal)
    private var chargerAlerts = ChargerAlerts()
    private var chargerRecheck: DispatchWorkItem?
    private var batteryWatch: io_object_t = 0

    private var wifiEnabled: Bool { defaults.bool(forKey: "reconnectWiFi") }

    func applicationDidFinishLaunching(_ note: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if others.contains(where: { $0 != .current }) { NSApp.terminate(nil); return }

        defaults.register(defaults: ["reconnectWiFi": true])
        // Wi-Fi reconnect only works while the app runs, so start at login by default.
        if !defaults.bool(forKey: "loginItemOffered") {
            defaults.set(true, forKey: "loginItemOffered")
            do { try SMAppService.mainApp.register() } catch { log.error("login item: \(error, privacy: .public)") }
        }

        // App Nap would stretch the tie timer to minutes. Holds no power assertion, so sleep still works.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "React to window and Wi-Fi events")

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        watchCharger()

        if wifiEnabled {
            startWiFiMonitor()
            refreshBluetoothState()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    private func updateIcon() {
        let warning = problem ?? chargerAlerts.active.first?.title
        let symbol = warning != nil ? "exclamationmark.triangle" : (awakeSince != nil ? "bolt.fill" : "bolt")
        let description = warning ?? (awakeSince != nil ? "KeepAwake: on" : "KeepAwake: off")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.appearsDisabled = warning == nil && awakeSince == nil // stay quiet in the menu bar when off
        statusItem.button?.toolTip = description
    }

    // MARK: Menu (rebuilt on open, so nothing updates in the background)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector? = nil, on: Bool = false, key: String = "", subtitle: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.state = on ? .on : .off
            item.isEnabled = action != nil
            if #available(macOS 14.4, *) { item.subtitle = subtitle }
            menu.addItem(item)
        }

        chargerChanged() // fresh reading for the charger lines below
        if let problem { add("⚠︎ \(problem)") }
        for issue in chargerAlerts.active { add((issue.danger ? "⛔︎ " : "⚠︎ ") + issue.title, subtitle: issue.tip) }
        if let awakeSince {
            let time = awakeSince.formatted(date: .omitted, time: .shortened)
            add("Awake since \(time)" + (tie.map { ", \($0.summary)" } ?? ""))
        }
        add("Keep Awake", #selector(toggleAwake), on: awakeSince != nil)

        // The status menu doesn't activate this app, so "frontmost" is still what the user was just using.
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front != .current, let name = front.localizedName {
            let window = frontWindow(of: front.processIdentifier)
            var isTiedToWindow = false, isTiedToApp = false
            if let tie, tie.pid == front.processIdentifier {
                if case .window(let id, _, _) = tie { isTiedToWindow = id == window } else { isTiedToApp = true }
            }
            add("Until This \(name) Window Closes", window != nil ? #selector(tieToWindow) : nil, on: isTiedToWindow)
            add("Until \(name) Quits", #selector(tieToApp), on: isTiedToApp)
        }

        if charger.connected {
            menu.addItem(.separator())
            add("\(charger.name ?? "Charger"): " + (charger.contractText.map { "\($0) max" } ?? "connected"))
            if let watts = charger.inWatts, let live = charger.liveText {
                let mac = fmt(max(0, watts - charger.battWatts), 1), battery = fmt(abs(charger.battWatts), 1)
                add("Using \(live)", subtitle: charger.battWatts >= 0
                    ? "\(mac)W runs the Mac, \(battery)W charges the battery"
                    : "The Mac uses \(mac)W, \(battery)W of it from the battery")
            } else {
                add("Using: measuring…", subtitle: "macOS updates this about once a minute")
            }
            if !charger.offers.isEmpty {
                add("Supports " + charger.offers.map { "\(fmt($0.volts, 1))V \(fmt($0.amps))A" }.joined(separator: " · "))
            }
        }

        menu.addItem(.separator())
        if wifiEnabled {
            add("Wi-Fi: " + wifiStatus())
            if bluetoothOff { add("⚠︎ Bluetooth is off: iPhone hotspot can't connect") }
            refreshBluetoothState() // shows on the next open; a process spawn must not delay this menu
        }
        add("Reconnect Wi-Fi Automatically", #selector(toggleWiFi), on: wifiEnabled)
        add("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add("Quit KeepAwake", #selector(NSApplication.terminate(_:)), key: "q")
        menu.items.last?.target = NSApp
    }

    // MARK: Keep awake

    @objc private func toggleAwake() {
        if guardFD >= 0 { disarm() } else { arm(tie: nil) }
    }

    @objc private func tieToWindow() {
        guard let front = NSWorkspace.shared.frontmostApplication, let name = front.localizedName,
              let id = frontWindow(of: front.processIdentifier) else { return }
        arm(tie: .window(id, front.processIdentifier, name))
    }

    @objc private func tieToApp() {
        guard let front = NSWorkspace.shared.frontmostApplication, let name = front.localizedName else { return }
        arm(tie: .app(front.processIdentifier, name))
    }

    private func arm(tie newTie: Tie?) {
        problem = nil
        setTie(newTie)
        if guardFD >= 0 { return }
        guard installHelperIfNeeded() else {
            setTie(nil)
            problem = "KeepAwake helper not installed"
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) {
            strlcpy($0.baseAddress!.assumingMemoryBound(to: CChar.self), socketPath, $0.count)
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            log.error("guard connect failed: \(errno, privacy: .public)")
            close(fd)
            setTie(nil)
            problem = "Could not reach KeepAwake helper"
            return
        }

        guardFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8)
            if read(fd, &buffer, buffer.count) > 0 {
                self.awakeSince = Date()
                self.updateIcon()
                log.notice("keep awake on")
            } else {
                self.disarm()
                self.problem = "Keep Awake stopped: helper exited"
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        guardSource = source
    }

    // Closing the socket is the whole off switch: the root guard restores sleep on EOF.
    private func disarm() {
        guardSource?.cancel()
        guardSource = nil
        guardFD = -1
        awakeSince = nil
        problem = nil
        setTie(nil)
        updateIcon()
        log.notice("keep awake off")
    }

    private func setTie(_ newTie: Tie?) {
        tie = newTie
        tieTimer?.invalidate()
        tieTimer = nil
        // shortcut: 10 s poll because window-closed events need the Accessibility permission; AXObserver is the upgrade if this delay ever matters.
        if case .window(let id, _, _) = newTie {
            let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                if !windowExists(id) { self?.tieEnded() }
            }
            timer.tolerance = 5
            tieTimer = timer
        }
    }

    private func tieEnded() {
        log.notice("tied target gone, ending keep awake")
        disarm()
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if let tie, app?.processIdentifier == tie.pid { tieEnded() }
    }

    // MARK: Wi-Fi

    private func wifiStatus() -> String {
        if online { return "Connected" }
        return CWWiFiClient.shared().interface()?.powerOn() == false ? "Turned off" : "Searching for known networks…"
    }

    private func refreshBluetoothState() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let off = bluetoothIsOff()
            DispatchQueue.main.async { self?.bluetoothOff = off }
        }
    }

    private func startWiFiMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // A VPN tunnel can report a route with no real network under it, so require a physical link.
            let physical = path.availableInterfaces.contains { [.wifi, .wiredEthernet, .cellular].contains($0.type) }
            self?.pathChanged(online: path.status == .satisfied && physical)
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func stopWiFiMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        wifiRetry?.cancel()
    }

    private func pathChanged(online isOnline: Bool) {
        if isOnline != online { log.notice("online: \(isOnline, privacy: .public)") }
        online = isOnline
        wifiRetry?.cancel()
        wifiAttempt = 0
        if !isOnline { scheduleWiFiNudge() }
    }

    private func scheduleWiFiNudge() {
        let work = DispatchWorkItem { [weak self] in self?.nudgeWiFi() }
        wifiRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay(attempt: wifiAttempt), execute: work)
        wifiAttempt += 1
    }

    // macOS holds the Wi-Fi passwords and refuses joins without them (-3900), so it has to do the
    // joining itself. A scan makes it auto-join any known network found, in the user's priority order.
    // Known networks get the first try, because the hotspot uses the phone's cellular data.
    private func nudgeWiFi() {
        guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn() else {
            scheduleWiFiNudge() // Wi-Fi switched off by the user: respect that, look again later.
            return
        }
        let retry = wifiRetry
        let trigger = wifiAttempt <= 1 ? AutoJoin.retry : AutoJoin.instantHotspot
        log.notice("offline, scanning for known networks")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? wifi.scanForNetworks(withSSID: nil)
            AutoJoin.request(trigger: trigger)
            let off = bluetoothIsOff()
            DispatchQueue.main.async {
                self?.bluetoothOff = off
                guard let self, retry?.isCancelled == false, !self.online else { return }
                self.scheduleWiFiNudge()
            }
        }
    }

    // MARK: Settings

    @objc private func toggleWiFi() {
        defaults.set(!wifiEnabled, forKey: "reconnectWiFi")
        if wifiEnabled { startWiFiMonitor() } else { stopWiFiMonitor() }
    }

    @objc private func toggleLogin() {
        problem = nil
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            problem = "Launch at Login failed: \(error.localizedDescription)"
        }
    }

    // MARK: Charger

    // Plug, unplug and charger changes, plus the battery update macOS publishes about once a minute.
    // Nothing polls: each event costs one registry read.
    private func watchCharger() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let powerSources = IOPSNotificationCreateRunLoopSource({ context in
            Unmanaged<App>.fromOpaque(context!).takeUnretainedValue().chargerChanged()
        }, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), powerSources, .defaultMode)

        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        IOServiceAddInterestNotification(port, battery, kIOGeneralInterest, { context, _, _, _ in
            Unmanaged<App>.fromOpaque(context!).takeUnretainedValue().chargerChanged()
        }, context, &batteryWatch)
        IOObjectRelease(battery)
        chargerChanged()
    }

    private func chargerChanged() {
        var reading = ChargerReading.read()
        for issue in chargerAlerts.update(&reading) { notify(issue) }
        charger = reading
        updateIcon()
        // A warning is only confirmed once it has lasted 4 s, so look once more when one is waiting.
        chargerRecheck?.cancel()
        guard chargerAlerts.pending else { return }
        let work = DispatchWorkItem { [weak self] in self?.chargerChanged() }
        chargerRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func notify(_ issue: ChargerIssue) {
        let content = UNMutableNotificationContent()
        content.title = (issue.danger ? "⛔️ " : "⚠️ ") + issue.title
        content.body = issue.tip
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        // Asks once, then answers at once; posting after the answer keeps the very first warning.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
        }
    }
}

// MARK: Charger readings (info only)

// What the charger offers (its USB-PD contract, known the moment it's plugged in) and what it
// delivers (macOS telemetry, refreshed about once a minute), plus warnings when it's bad for the Mac.
// Units: volts, amps, watts, °C.
struct ChargerReading {
    var connected = false
    var name: String?
    var watts: Double?
    var volts: Double?
    var amps: Double?
    var offers: [(volts: Double, amps: Double)] = []
    var inVolts: Double?
    var inAmps: Double?
    var battVolts = 0.0
    var battAmps = 0.0 // > 0 charging, < 0 draining
    var tempC: Double?
    var thermal: ProcessInfo.ThermalState = .nominal
    var updated: Date? // when macOS last refreshed the telemetry

    var battWatts: Double { battVolts * battAmps }
    var inWatts: Double? {
        guard let v = inVolts, let a = inAmps, v > 0, a > 0 else { return nil }
        return v * a
    }
    var contractText: String? {
        guard let v = volts, let a = amps else { return watts.map { "\(fmt($0, 0))W" } }
        return "\(fmt(watts ?? v * a, 0))W (\(fmt(v, 1))V × \(fmt(a))A)"
    }
    var liveText: String? {
        guard let w = inWatts, let v = inVolts, let a = inAmps else { return nil }
        return "\(fmt(w, 1))W (\(fmt(v, 1))V × \(fmt(a))A)"
    }

    static func read() -> ChargerReading {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { IOObjectRelease(battery) }
        var properties: Unmanaged<CFMutableDictionary>?
        IORegistryEntryCreateCFProperties(battery, &properties, kCFAllocatorDefault, 0)
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        return ChargerReading(battery: properties?.takeRetainedValue() as? [String: Any] ?? [:], adapter: adapter,
                              thermal: ProcessInfo.processInfo.thermalState)
    }

    // AppleSmartBattery properties and IOPS adapter details, in mV, mA and W.
    init(battery: [String: Any], adapter: [String: Any]?, thermal: ProcessInfo.ThermalState) {
        // IOKit reports signed values such as Amperage as unsigned 64-bit; int64Value restores the sign.
        func number(_ d: [String: Any]?, _ key: String) -> Double? { (d?[key] as? NSNumber).map { Double($0.int64Value) } }
        self.thermal = thermal
        connected = battery["ExternalConnected"] as? Bool ?? false
        battVolts = (number(battery, "Voltage") ?? 0) / 1000
        battAmps = (number(battery, "Amperage") ?? 0) / 1000
        updated = number(battery, "UpdateTime").map { Date(timeIntervalSince1970: $0) }
        tempC = (number(battery, "Temperature") ?? number(battery, "VirtualTemperature")).map { $0 / 100 } // gone on macOS 27
        guard connected else { return }

        var details = battery["AdapterDetails"] as? [String: Any] ?? [:]
        details.merge(adapter ?? [:]) { $1 }
        name = details["Name"] as? String
        watts = number(details, "Watts").flatMap { $0 > 0 ? $0 : nil }
        volts = (number(details, "AdapterVoltage") ?? number(details, "Voltage")).flatMap { $0 > 0 ? $0 / 1000 : nil }
        amps = number(details, "Current").flatMap { $0 > 0 ? $0 / 1000 : nil }
        offers = (details["UsbHvcMenu"] as? [[String: Any]] ?? []).compactMap {
            guard let v = number($0, "MaxVoltage"), let a = number($0, "MaxCurrent") else { return nil }
            return (v / 1000, a / 1000)
        }
        let telemetry = battery["PowerTelemetryData"] as? [String: Any]
        inVolts = number(telemetry, "SystemVoltageIn").map { $0 / 1000 }
        inAmps = number(telemetry, "SystemCurrentIn").map { $0 / 1000 }
    }

    // Problems in this one reading, dangers first.
    var issues: [ChargerIssue] {
        guard connected else { return [] }
        var out: [ChargerIssue] = []
        if let v = volts, let measured = inVolts, measured > 0 {
            if measured > v * 1.1 {
                out.append(ChargerIssue(id: "overvolt", danger: true, title: "Voltage too high: \(fmt(measured, 1))V on a \(fmt(v, 1))V charger",
                                        tip: "The charger is sending more voltage than it agreed to. Unplug it now: it may be faulty."))
            } else if measured < v * 0.85, (inAmps ?? 0) > 0.5 {
                out.append(ChargerIssue(id: "sag", danger: false, title: "Voltage dropping: \(fmt(measured, 1))V of \(fmt(v, 1))V",
                                        tip: "The charger or cable can't hold its voltage under load. Try another cable (short, 100W/e-marked) or charger."))
            }
        }
        if let v = volts, v <= 5.5 {
            out.append(ChargerIssue(id: "5v", danger: false, title: "5V-only charger (\(contractText ?? "?"))",
                                    tip: "A phone-style charger with no USB-PD fast charging. The Mac charges very slowly or drains. Use a USB-C PD charger of 30W or more."))
        } else if let w = watts, w < 30 {
            out.append(ChargerIssue(id: "lowwatt", danger: false, title: "Low-power charger (\(fmt(w, 0))W)",
                                    tip: "Too weak for a MacBook under load: expect slow charging or drain. Use 30W or more, ideally the wattage your Mac came with."))
        }
        // Only while power really flows in: right after plug-in macOS can wait about a minute before using the charger.
        if battAmps < -0.1, inWatts != nil {
            out.append(ChargerIssue(id: "drain", danger: false, title: "Battery draining while plugged in (\(fmt(-battWatts, 1))W)",
                                    tip: "The charger can't keep up with the Mac. Use a stronger charger or close heavy apps."))
        }
        if let t = tempC, t >= 40 {
            out.append(ChargerIssue(id: "temp", danger: t >= 45, title: "Battery \(t >= 45 ? "hot" : "warm") (\(fmt(t, 1))°C)",
                                    tip: t >= 45 ? "Unplug and let the Mac cool down." : "Charging while warm wears the battery. Give it airflow or unplug."))
        }
        if thermal == .serious || thermal == .critical {
            out.append(ChargerIssue(id: "hot", danger: false, title: "Mac is running hot while charging",
                                    tip: "Heat plus charging ages the battery fastest. Unplug or give it airflow."))
        }
        return out.filter(\.danger) + out.filter { !$0.danger }
    }
}

struct ChargerIssue {
    let id: String
    let danger: Bool
    let title: String
    let tip: String
}

// Turns readings into warnings. Each must last 4 s, because a charger steps through 5V while it
// negotiates; readings taken before the current charger settled in are ignored, because they
// belong to the previous one; and each warning notifies once until it clears.
struct ChargerAlerts {
    private(set) var active: [ChargerIssue] = []
    private var since: [String: Date] = [:]
    private var notified: Set<String> = []
    private var connects: [Date] = []
    private var started = false
    private var wasConnected = false
    private var contract: String?
    private var contractSince = Date.distantPast

    var pending: Bool { since.count > active.count }

    // Returns the warnings to notify about, and blanks live readings in `reading` that predate the charger.
    mutating func update(_ reading: inout ChargerReading, now: Date = Date()) -> [ChargerIssue] {
        if reading.connected {
            if started && !wasConnected { connects.append(now) }
            if reading.contractText != contract {
                contract = reading.contractText
                contractSince = started ? now : .distantPast // already plugged in at launch: its readings are current
            }
        } else {
            contract = nil
        }
        started = true
        wasConnected = reading.connected
        connects.removeAll { now.timeIntervalSince($0) > 60 }
        if reading.connected, let updated = reading.updated, updated.timeIntervalSince(contractSince) < 20 {
            reading.inVolts = nil
            reading.inAmps = nil
        }

        var found = reading.issues
        if connects.count >= 3 {
            found.insert(ChargerIssue(id: "flapping", danger: true, title: "Charger keeps disconnecting",
                                      tip: "A loose cable or port, or a failing charger. Unplug it and try another cable or charger."), at: 0)
        }
        let ids = Set(found.map(\.id))
        since = since.filter { ids.contains($0.key) }
        for id in ids where since[id] == nil { since[id] = now }
        active = found.filter { now.timeIntervalSince(since[$0.id]!) >= 4 }
        notified.formIntersection(active.map(\.id))
        return active.filter { notified.insert($0.id).inserted }
    }
}

// Locale-independent number: up to `digits` decimals, trailing zeros trimmed.
func fmt(_ x: Double, _ digits: Int = 2) -> String {
    var s = String(format: "%.\(digits)f", x)
    while s.contains("."), s.hasSuffix("0") || s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

// Run by install.sh before anything is installed.
func selfCheck() {
    precondition(retryDelay(attempt: 0) == 15 && retryDelay(attempt: 1) == 30 && retryDelay(attempt: 50) == 300, "Wi-Fi backoff")

    precondition(isBluetoothOffReport("\"controller_state\" : \"attrib_off\""), "Bluetooth off")
    precondition(!isBluetoothOffReport("\"controller_state\" : \"attrib_on\""), "Bluetooth on")

    let plists = daemonPlists(uid: 501)
    precondition(plists.map(\.label) == [guardLabel, resetLabel], "daemon labels")
    let parsed = try! PropertyListSerialization.propertyList(from: plists[0].data, format: nil) as! [String: Any]
    let listener = (parsed["Sockets"] as! [String: Any])["Listener"] as! [String: Any]
    precondition(listener["SockPathMode"] as? Int == 0o600 && listener["SockPathOwner"] as? Int == 501, "socket restricted to the user")
    precondition(plists.map(\.data) == daemonPlists(uid: 501).map(\.data), "plist bytes stable, or every launch would re-prompt")

    chargerCheck()

    // A real window through the real checks, off screen.
    NSApplication.shared.setActivationPolicy(.prohibited)
    var window: NSWindow? = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 200, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
    window?.isReleasedWhenClosed = false
    window?.alphaValue = 0
    window?.orderFrontRegardless()
    let id = CGWindowID(window!.windowNumber)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    precondition(windowExists(id), "open window is found")
    precondition(frontWindow(of: getpid()) == id, "front window of an app is found")
    window?.close()
    window = nil
    // A close only commits with a running event loop, so "closed" is proven by the live test in the README.
    precondition(!windowExists(99_999_999), "unknown window is gone")
    print("selfcheck ok")
}

// Real readings from a MacBook Pro (Mac16,1), in IOKit's own units and encodings.
func chargerCheck() {
    func battery(amps: Int, vin: Int = 0, iin: Int = 0, adapter: [String: Any], connected: Bool = true, updated: Int? = nil) -> [String: Any] {
        var b: [String: Any] = [
            "ExternalConnected": connected, "Voltage": 11888,
            "Amperage": NSNumber(value: UInt64(bitPattern: Int64(amps))), // negative mA arrive as unsigned 64-bit
            "PowerTelemetryData": ["SystemVoltageIn": vin, "SystemCurrentIn": iin],
            "AdapterDetails": adapter,
        ]
        b["UpdateTime"] = updated
        return b
    }
    func menu(_ offers: [[Int]]) -> [[String: Any]] { offers.map { ["MaxVoltage": $0[0], "MaxCurrent": $0[1]] } }
    func reading(_ b: [String: Any], thermal: ProcessInfo.ThermalState = .nominal) -> ChargerReading {
        ChargerReading(battery: b, adapter: nil, thermal: thermal)
    }
    let ugreen30: [String: Any] = ["AdapterVoltage": 20000, "Watts": 30, "Current": 1500, "Description": "pd charger",
                                   "UsbHvcMenu": menu([[5000, 3000], [9000, 3000], [12000, 2500], [15000, 2000], [20000, 1500]])]
    let generic18: [String: Any] = ["AdapterVoltage": 12000, "Watts": 18, "Current": 1500,
                                    "UsbHvcMenu": menu([[5000, 3000], [9000, 2000], [12000, 1500]])]
    let phone15: [String: Any] = ["Voltage": 5000, "Watts": 15, "Current": 3000] // older macOS name for the voltage

    // Ugreen right after plug-in: macOS hasn't started using it, so the draining battery isn't its fault.
    let waiting = reading(battery(amps: -515, adapter: ugreen30))
    precondition(waiting.contractText == "30W (20V × 1.5A)", "contract")
    precondition(waiting.offers.map { "\(fmt($0.volts))V \(fmt($0.amps))A" } == ["5V 3A", "9V 3A", "12V 2.5A", "15V 2A", "20V 1.5A"], "offers")
    precondition(waiting.battAmps == -0.515 && waiting.issues.isEmpty, "signed amps, no drain warning before power flows")
    let charging = reading(battery(amps: 1572, vin: 19530, iin: 1443, adapter: ugreen30))
    precondition(charging.liveText == "28.2W (19.5V × 1.44A)" && charging.issues.isEmpty, "30W charging is fine")

    precondition(reading(battery(amps: 426, vin: 11526, iin: 1427, adapter: generic18)).issues.map(\.id) == ["lowwatt"], "18W is low")
    precondition(reading(battery(amps: -506, vin: 5000, iin: 2000, adapter: phone15)).issues.map(\.id) == ["5v", "drain"], "5V and drain")
    precondition(reading(battery(amps: 1000, vin: 22600, iin: 1000, adapter: ugreen30)).issues.first?.id == "overvolt", "overvoltage")
    precondition(reading(battery(amps: 1000, vin: 16000, iin: 2000, adapter: ugreen30)).issues.map(\.id) == ["sag"], "voltage sag")
    precondition(reading(battery(amps: 1000, adapter: ugreen30), thermal: .serious).issues.map(\.id) == ["hot"], "hot")
    precondition(reading(battery(amps: -800, adapter: ["FamilyCode": 0], connected: false)).issues.isEmpty, "on battery: no charger rules")

    // A warning is confirmed after 4 s and notified once.
    var alerts = ChargerAlerts()
    let t0 = Date(timeIntervalSince1970: 1000)
    var r = reading(battery(amps: 1000, vin: 5000, iin: 2900, adapter: phone15))
    precondition(alerts.update(&r, now: t0).isEmpty && alerts.pending, "waits before warning")
    precondition(alerts.update(&r, now: t0 + 5).map(\.id) == ["5v"] && !alerts.pending, "warns once confirmed")
    precondition(alerts.update(&r, now: t0 + 10).isEmpty && alerts.active.map(\.id) == ["5v"], "no repeat")

    // Swapping to a 5V charger while macOS still reports the old 20V reading must not look like overvoltage.
    alerts = ChargerAlerts()
    r = reading(battery(amps: 1000, vin: 19900, iin: 1000, adapter: ugreen30, updated: 990))
    _ = alerts.update(&r, now: t0)
    precondition(r.liveText != nil, "plugged in at launch: reading is current")
    for i in 1...3 {
        r = reading(battery(amps: 1000, vin: 19900, iin: 1000, adapter: phone15, updated: 990))
        _ = alerts.update(&r, now: t0 + Double(i) * 5)
        precondition(r.liveText == nil && !alerts.active.contains { $0.id == "overvolt" }, "stale reading ignored")
    }
    r = reading(battery(amps: 1000, vin: 5100, iin: 2900, adapter: phone15, updated: 1030))
    _ = alerts.update(&r, now: t0 + 35)
    precondition(r.liveText == "14.8W (5.1V × 2.9A)", "fresh reading used")

    // Three plug-ins within a minute.
    alerts = ChargerAlerts()
    let on = reading(battery(amps: 1000, adapter: ugreen30)), off = reading(battery(amps: -500, adapter: [:], connected: false))
    var warned: [String] = []
    for i in 0..<10 {
        r = i % 2 == 0 ? on : off
        warned += alerts.update(&r, now: t0 + Double(i) * 3).map(\.id)
    }
    precondition(warned == ["flapping"], "flapping charger")

    precondition(fmt(20) == "20" && fmt(3.25) == "3.25" && fmt(0.5) == "0.5" && fmt(19.85, 1) == "19.9" && fmt(-0.001, 1) == "0", "fmt")
}

switch CommandLine.arguments.dropFirst().first {
case "--selfcheck":
    selfCheck()
case "--guard-plist": // for test_guard.sh
    FileHandle.standardOutput.write(daemonPlists(uid: Int(getuid()))[0].data)
default:
    let delegate = App()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
