import Foundation

enum LockState: String, Codable { case locked, unlocked, unknown }
struct Snapshot: Equatable {
    var state: LockState = .unknown
    var sessionOK = false
    var sessionID: Int64 = -1
    var ax = false
    var post = false
    var targetOK = false
    var targetReason = "password_target_unverified"
    var emptyFieldVerified = false
}
func policy(_ s: Snapshot, authorized: Bool, clearFirst: Bool = false) -> String {
    guard authorized else { return "authorization_required" }
    guard s.sessionOK else { return "session_unverified" }
    if s.state == .unlocked { return "already_unlocked" }
    guard s.state == .locked else { return "lock_unknown" }
    guard s.ax && s.post else { return "input_permission_missing" }
    guard s.targetOK else { return s.targetReason }
    guard s.emptyFieldVerified || clearFirst else { return "empty_password_field_unverified" }
    return "ready"
}
func consistent(_ a: Snapshot, _ b: Snapshot) -> Bool {
    a.sessionOK && b.sessionOK && a.sessionID > 0 && a.sessionID == b.sessionID
}
struct Receipt: Codable {
    let command: String
    let result: String
    let lockState: LockState
    let submitted: Bool
    let code: Int32
    let sessionVerified: Bool
    let accessibility: Bool
    let postEvents: Bool
    let passwordTargetVerified: Bool
    let credential: String
    var targetReason: String = "not_checked"
    var emptyFieldVerified: Bool = false
    var inputStrategy: String = "require_verified_empty"
}
enum InputResult { case refused, partial, submitted }
func sendPairs(count: Int, validate: () -> Bool, post: (Int) -> Void) -> InputResult {
    var sent = false
    for pair in 0..<count {
        guard validate() else { return sent ? .partial : .refused }
        post(pair)
        sent = true
    }
    return .submitted
}
func unicodeRanges(_ units: [UInt16]) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var start = 0
    while start < units.count {
        var end = min(start + 20, units.count)
        if end < units.count && (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
        ranges.append(start..<end)
        start = end
    }
    return ranges
}
// Shared one-attempt flow. Test closures are synthetic; production closures are native.
func attempt(initial: Snapshot, authorized: Bool, clearFirst: Bool = false,
             read: () -> Bool, recheck: () -> Snapshot,
             submit: () -> InputResult, wait: () -> Snapshot) -> (String, Bool) {
    let decision = policy(initial, authorized: authorized, clearFirst: clearFirst)
    guard decision == "ready" else { return (decision, false) }
    guard read() else { return ("credential_blocked", false) }
    let before = recheck()
    guard consistent(initial, before), policy(before, authorized: true, clearFirst: clearFirst) == "ready" else {
        return ("state_changed_before_input", false)
    }
    switch submit() {
    case .refused: return ("input_refused", false)
    case .partial: return ("partial_input_aborted_no_retry", true)
    case .submitted: break
    }
    let after = wait()
    guard consistent(initial, after) else { return ("session_changed_after_input", true) }
    return (after.state == .unlocked ? "unlocked_confirmed" : "confirmation_timeout_no_retry", true)
}

func targetGuard(identity: Bool, uidMatches: Bool, pidMatches: Bool, role: String?, subrole: String?, enabled: Bool?, focused: Bool?) -> String {
    guard identity && uidMatches else { return "loginwindow_identity_or_uid_unverified" }
    guard pidMatches else { return "field_pid_unverified" }
    guard role == "AXTextField" else { return "field_role_unverified" }
    guard subrole == "AXSecureTextField" else { return "field_secure_subrole_unverified" }
    guard enabled == true else { return "field_enabled_unverified" }
    guard focused == true else { return "field_focused_unverified" }
    return "verified"
}

enum InputStep: Equatable { case selectAll, delete, text(Range<Int>), enter }
func inputSteps(_ units: [UInt16], clearFirst: Bool) -> [InputStep] {
    (clearFirst ? [.selectAll, .delete] : []) + unicodeRanges(units).map { .text($0) } + [.enter]
}
