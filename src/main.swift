import Foundation
import CoreGraphics
import Darwin

let args = Array(CommandLine.arguments.dropFirst())
let help = """
mac-unlock --help
mac-unlock status
mac-unlock preflight [--clear-first]
mac-unlock unlock --dry-run [--clear-first]
mac-unlock setup --local-user
mac-unlock unlock --authorize [--clear-first]
mac-unlock relock --authorize

status/preflight/dry-run: no credential access, prompts, or input.
Double-click installed App (no arguments): local masked setup, own unlocked session only.
setup: user-only masked local UI; install at ~/Applications/MacUnlock.app first.
unlock/relock: caller must obtain explicit authorization for this machine action.
No wake, first login, FileVault, retries, daemon, or remote listener.
JSON exit codes: 0 confirmed/no-op, 2 blocked, 3 attempted but unconfirmed, 64 usage.
"""
if args == ["--help"] || args == ["help"] { print(help); exit(0) }
let requestedCommand = args.first ?? "setup"
let command = ["status", "preflight", "unlock", "relock", "setup"].contains(requestedCommand) ? requestedCommand : "invalid"
let clearFirst = args.contains("--clear-first")
let valid = args.isEmpty || args == ["status"] || args == ["preflight"] || args == ["unlock", "--dry-run"] ||
    args == ["unlock", "--authorize"] || args == ["relock", "--authorize"] || args == ["setup", "--local-user"] || args == ["preflight", "--clear-first"] ||
    args == ["unlock", "--dry-run", "--clear-first"] || args == ["unlock", "--authorize", "--clear-first"]
var s = Snapshot()
var credential = "not_queried"
func emit(_ result: String, submitted: Bool = false, code: Int32) -> Never {
    let receipt = Receipt(command: command, result: result, lockState: s.state, submitted: submitted,
                          code: code, sessionVerified: s.sessionOK, accessibility: s.ax,
                          postEvents: s.post, passwordTargetVerified: s.targetOK, credential: credential, targetReason: s.targetReason, emptyFieldVerified: s.emptyFieldVerified, inputStrategy: clearFirst ? "clear_first_once" : "require_verified_empty")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(receipt), let json = String(data: data, encoding: .utf8) { print(json) }
    exit(code)
}
guard valid else { emit("invalid_arguments_use_help", code: 64) }
s = snapshot()
if command == "status" { emit(s.sessionOK && s.state != .unknown ? "observed" : "unknown", code: s.sessionOK && s.state != .unknown ? 0 : 2) }
if command == "preflight" || args.contains("--dry-run") {
    let decision = policy(s, authorized: true, clearFirst: clearFirst)
    emit(decision, code: decision == "ready" || decision == "already_unlocked" ? 0 : 2)
}
// Authorization required by exact argument grammar; no implicit screen actions.
guard let fd = acquireLock(directory: NSTemporaryDirectory() + "mac-unlock-\(getuid())") else { emit("busy_or_lock_unavailable", code: 2) }
defer { close(fd) }
if command == "setup" {
    let result = setup()
    emit(result, code: result == "password_saved" ? 0 : 2)
}
if command == "relock" {
    guard s.sessionOK, s.state != .unknown else { emit("session_or_lock_unverified", code: 2) }
    if s.state == .locked { emit("already_locked", code: 0) }
    guard s.ax && s.post else { emit("input_permission_missing", code: 2) }
    let before = snapshot()
    guard consistent(s, before), before.state == .unlocked else { emit("state_changed_before_input", code: 2) }
    // Native Control-Command-Q; no password or privileged plugin.
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) else { emit("event_unavailable", code: 2) }
    down.flags = [.maskControl, .maskCommand]
    up.flags = [.maskControl, .maskCommand]
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
    let after = confirmation(from: s, desired: .locked)
    let success = consistent(s, after) && after.state == .locked
    s = after
    emit(success ? "locked_confirmed" : "relock_unconfirmed_no_retry", submitted: true, code: success ? 0 : 3)
}
var secret: Data?
var target: Target?
let initial = s
let outcome = attempt(initial: initial, authorized: true, clearFirst: clearFirst, read: {
    // Bind focus before fetching; revalidate same AX object before every event pair.
    target = passwordTarget()
    guard let target, sameTarget(target, session: initial), clearFirst || emptyField(target.element) else { return false }
    credential = "requested_own_item"
    secret = fetchOwnSecret()
    return secret != nil
}, recheck: { snapshot() }, submit: {
    guard let secret, let target else { return .refused }
    return submitPassword(secret, target: target, session: initial, clearFirst: clearFirst)
}, wait: {
    s = confirmation(from: initial, desired: .unlocked)
    return s
})
if secret != nil { secret!.resetBytes(in: 0..<secret!.count); secret = nil }
if !outcome.1 { s = snapshot() }
let success = outcome.0 == "unlocked_confirmed" || outcome.0 == "already_unlocked"
emit(outcome.0, submitted: outcome.1, code: success ? 0 : outcome.1 ? 3 : 2)
