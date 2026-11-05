// KeepAwake: menu bar app that keeps the Mac running with the lid closed and rejoins
// known Wi-Fi. macOS itself does the locking. Everything is event-driven; see README.md.
import AppKit
import CoreWLAN
import Network
import ServiceManagement
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

        if wifiEnabled {
            startWiFiMonitor()
            refreshBluetoothState()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    private func updateIcon() {
        let symbol = problem != nil ? "exclamationmark.triangle" : (awakeSince != nil ? "bolt.fill" : "bolt")
        let description = problem ?? (awakeSince != nil ? "KeepAwake: on" : "KeepAwake: off")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.appearsDisabled = problem == nil && awakeSince == nil // stay quiet in the menu bar when off
        statusItem.button?.toolTip = description
    }

    // MARK: Menu (rebuilt on open, so nothing updates in the background)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector? = nil, on: Bool = false, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.state = on ? .on : .off
            item.isEnabled = action != nil
            menu.addItem(item)
        }

        if let problem { add("⚠︎ \(problem)") }
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
