import AppKit
import ApplicationServices
import Security
import SystemConfiguration
import IOKit
import Darwin

let identity = "com.example.MacUnlock"
let service = "com.example.MacUnlock.password"
let installedPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Applications/MacUnlock.app/Contents/MacOS/mac-unlock").path

func exactBool(_ value: Any?) -> Bool? {
    guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
    return (value as! NSNumber).boolValue
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
struct Target {
    let pid: pid_t
    let element: AXUIElement
}
func processUID(_ pid: pid_t) -> uid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size else { return nil }
    return info.kp_eproc.e_ucred.cr_uid
}
func loginwindow() -> NSRunningApplication? {
    var pids = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
    if let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
        for window in windows { if let pid = window[kCGWindowOwnerPID as String] as? Int32 { pids.insert(pid) } }
    }
    let matches = pids.compactMap { NSRunningApplication(processIdentifier: $0) }.filter {
        $0.bundleIdentifier == "com.apple.loginwindow" &&
        $0.executableURL?.path == "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow" &&
        !$0.isTerminated && processUID($0.processIdentifier) == getuid()
    }
    return matches.count == 1 ? matches[0] : nil
}
func locatePasswordTarget() -> (Target?, String) {
    guard let running = loginwindow() else { return (nil, "loginwindow_identity_or_uid_unverified") }
    let pid = running.processIdentifier
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var raw: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw)
    guard error == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
        return (nil, "loginwindow_focused_element_error_\(error.rawValue)")
    }
    let field = raw as! AXUIElement
    AXUIElementSetMessagingTimeout(field, 0.3)
    var fieldPID: pid_t = 0
    let reason = targetGuard(identity: true, uidMatches: processUID(pid) == getuid(),
        pidMatches: AXUIElementGetPid(field, &fieldPID) == .success && fieldPID == pid,
        role: attribute(field, kAXRoleAttribute) as? String,
        subrole: attribute(field, kAXSubroleAttribute) as? String,
        enabled: exactBool(attribute(field, kAXEnabledAttribute)), focused: exactBool(attribute(field, kAXFocusedAttribute)))
    return reason == "verified" ? (Target(pid: pid, element: field), reason) : (nil, reason)
}
func passwordTarget() -> Target? { locatePasswordTarget().0 }
func emptyField(_ field: AXUIElement) -> Bool {
    guard let count = attribute(field, kAXNumberOfCharactersAttribute) as? NSNumber,
          CFGetTypeID(count) != CFBooleanGetTypeID(), count.doubleValue == 0 else { return false }
    return true
}
func snapshot(checkTarget: Bool = true) -> Snapshot {
    var s = Snapshot()
    s.ax = AXIsProcessTrusted()
    s.post = CGPreflightPostEventAccess()
    guard getuid() != 0, getuid() == geteuid(),
          let cg = CGSessionCopyCurrentDictionary() as? [String: Any],
          let uid = cg[kCGSessionUserIDKey as String] as? NSNumber,
          uid.uint32Value == getuid(),
          exactBool(cg[kCGSessionOnConsoleKey as String]) == true,
          exactBool(cg[kCGSessionLoginDoneKey as String]) == true,
          let sid = cg["kSCSecuritySessionID"] as? NSNumber,
          CFGetTypeID(sid) != CFBooleanGetTypeID(),
          sid.int64Value > 0, sid.int64Value <= Int64(UInt32.max),
          sid.doubleValue == Double(sid.int64Value) else { return s }
    var securityID: SecuritySessionId = 0
    var securityAttributes: SessionAttributeBits = []
    // ConsoleSetKey is absent on macOS 27.2. Bind the console's available
    // security-session identity to the caller via the public Security API.
    guard SessionGetInfo(callerSecuritySession, &securityID, &securityAttributes) == errSecSuccess,
          sid.uint32Value == securityID else { return s }
    var consoleUID: uid_t = 0
    var consoleGID: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID) as String?,
          name != "loginwindow", name != "_mbsetupuser", consoleUID == getuid() else { return s }
    var st = stat()
    guard lstat("/dev/console", &st) == 0, st.st_uid == getuid() else { return s }
    s.sessionOK = true
    s.sessionID = sid.int64Value
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    if root != 0 {
        defer { IOObjectRelease(root) }
        if let raw = IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
           let locked = exactBool(raw) { s.state = locked ? .locked : .unlocked }
    }
    if checkTarget && s.state == .locked && s.ax && s.post {
        let found = locatePasswordTarget()
        s.targetReason = found.1
        s.targetOK = found.0 != nil
        if let target = found.0 { s.emptyFieldVerified = emptyField(target.element) }
    }
    return s
}
// Secure private per-user directory and nonblocking flock, shared by setup/unlock/relock.
func acquireLock(directory: String) -> Int32? {
    if mkdir(directory, 0o700) != 0 && errno != EEXIST { return nil }
    let dir = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard dir >= 0 else { return nil }
    defer { close(dir) }
    var st = stat()
    guard fstat(dir, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700 else { return nil }
    let fd = openat(dir, "exclusive.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return nil }
    guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_nlink == 1,
          st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o777 == 0o600,
          flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
    return fd
}
func ownQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: "uid:\(getuid())",
     kSecAttrSynchronizable as String: false,
     kSecUseDataProtectionKeychain as String: false]
}
func fetchOwnSecret() -> Data? {
    // Disable interaction for the entire process; refusal/locked/missing never prompts.
    guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return nil }
    var query = ownQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
}
func validPassword(_ string: String) -> Bool {
    !string.isEmpty && string.utf16.count <= 256 &&
    !string.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}
func setup() -> String {
    let initial = snapshot()
    guard initial.sessionOK, initial.state == .unlocked else { return "setup_requires_unlocked_own_session" }
    guard let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
          path == installedPath, Bundle.main.bundleIdentifier == identity else { return "install_at_stable_path_first" }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
          let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return "signature_invalid" }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let alert = NSAlert()
    alert.messageText = "MacUnlock：仅在本机输入登录密码"
    alert.informativeText = "密码只保存在此用户的独立钥匙串条目中。不要通过聊天、命令或剪贴板提供。"
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    app.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return "setup_cancelled" }
    let password = field.stringValue
    field.stringValue = ""
    guard validPassword(password) else { return "password_format_unsupported" }
    let after = snapshot()
    guard consistent(initial, after), after.state == .unlocked else { return "session_changed_during_setup" }
    var trusted: SecTrustedApplication?
    guard SecTrustedApplicationCreateFromPath(path, &trusted) == errSecSuccess, let trusted else { return "trusted_access_failed" }
    var access: SecAccess?
    guard SecAccessCreate("MacUnlock dedicated login password" as CFString, [trusted] as CFArray, &access) == errSecSuccess,
          let access else { return "trusted_access_failed" }
    var data = Data(password.utf8)
    defer { data.resetBytes(in: 0..<data.count) }
    let updates: [String: Any] = [kSecValueData as String: data, kSecAttrAccess as String: access]
    let query = ownQuery()
    let update = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
    if update == errSecSuccess { return "password_saved" }
    guard update == errSecItemNotFound else { return "keychain_save_blocked" }
    var add = query
    updates.forEach { add[$0.key] = $0.value }
    add[kSecAttrLabel as String] = "MacUnlock (own item)"
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? "password_saved" : "keychain_save_blocked"
}
func sameTarget(_ target: Target, session: Snapshot) -> Bool {
    let now = snapshot(checkTarget: false)
    guard consistent(session, now), now.state == .locked, now.ax && now.post,
          let current = passwordTarget() else { return false }
    return current.pid == target.pid && CFEqual(current.element, target.element)
}
// Mechanism informed by ts1/BLEUnlock AppDelegate.swift at 2eeb35d.
// Pin events to the validated loginwindow PID rather than global HID routing.
// Public AX/CG APIs cannot make focus validation + event delivery atomic.
func submitPassword(_ data: Data, target: Target, session: Snapshot, clearFirst: Bool = false) -> InputResult {
    guard let string = String(data: data, encoding: .utf8), validPassword(string),
          let source = CGEventSource(stateID: .hidSystemState),
          clearFirst || emptyField(target.element) else { return .refused }
    var units = Array(string.utf16)
    defer { _ = units.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
    let steps = inputSteps(units, clearFirst: clearFirst)
    var events: [CGEvent] = []
    // Allocate the complete preparation/text/Return sequence before any input.
    for step in steps {
        let key: CGKeyCode
        switch step {
        case .selectAll: key = 0
        case .delete: key = 51
        case .text: key = 49
        case .enter: key = 36
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return .refused }
        down.flags = step == .selectAll ? .maskCommand : []
        up.flags = []
        if case .text(let range) = step {
            units.withUnsafeBufferPointer {
                down.keyboardSetUnicodeString(stringLength: range.count, unicodeString: $0.baseAddress! + range.lowerBound)
            }
        }
        events += [down, up]
    }
    return sendPairs(count: steps.count, validate: { sameTarget(target, session: session) }, post: { pair in
        events[pair * 2].postToPid(target.pid)
        events[pair * 2 + 1].postToPid(target.pid)
        // Allow selection/deletion processing before the next guarded pair; not proof of clearing.
        if steps[pair] == .selectAll || steps[pair] == .delete { Thread.sleep(forTimeInterval: 0.1) }
    })
}
func confirmation(from initial: Snapshot, desired: LockState) -> Snapshot {
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    var current = initial
    repeat {
        current = snapshot()
        if !consistent(initial, current) || current.state == desired { return current }
        Thread.sleep(forTimeInterval: 0.2)
    } while ProcessInfo.processInfo.systemUptime < deadline
    return current
}

// Read-only metadata; line range is diagnostic evidence, not yet an emptiness fallback.
