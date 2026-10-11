import Foundation
import Darwin

@main struct Tests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError("FAIL: \(name)") }
            checks += 1
        }
        let ready = Snapshot(state: .locked, sessionOK: true, sessionID: 9, ax: true, post: true, targetOK: true, emptyFieldVerified: true)
        check(targetGuard(identity: false, uidMatches: true, pidMatches: true, role: "AXTextField", subrole: "AXSecureTextField", enabled: true, focused: true) != "verified", "reject non-loginwindow")
        check(targetGuard(identity: true, uidMatches: false, pidMatches: true, role: "AXTextField", subrole: "AXSecureTextField", enabled: true, focused: true) != "verified", "reject other UID")
        check(targetGuard(identity: true, uidMatches: true, pidMatches: false, role: "AXTextField", subrole: "AXSecureTextField", enabled: true, focused: true) != "verified", "reject wrong PID")
        check(targetGuard(identity: true, uidMatches: true, pidMatches: true, role: "AXTextField", subrole: "AXTextField", enabled: true, focused: true) != "verified", "reject nonsecure field")
        var unknownEmpty = ready; unknownEmpty.emptyFieldVerified = false
        var prohibitedCalls = 0
        let blockedEmpty = attempt(initial: unknownEmpty, authorized: true, read: { prohibitedCalls += 1; return true }, recheck: { ready }, submit: { prohibitedCalls += 1; return .submitted }, wait: { ready })
        check(blockedEmpty.0 == "empty_password_field_unverified" && prohibitedCalls == 0, "unknown empty field never reads secret or sends input")
        check(policy(unknownEmpty, authorized: true, clearFirst: true) == "ready" && !unknownEmpty.emptyFieldVerified, "clear-first does not forge empty evidence")
        check(policy(unknownEmpty, authorized: false, clearFirst: true) == "authorization_required", "unapproved clear-first blocked")
        let steps = inputSteps(Array("synthetic".utf16), clearFirst: true)
        check(steps == [.selectAll, .delete, .text(0..<9), .enter], "exact single clear/type/submit order")
        check(inputSteps(Array("synthetic".utf16), clearFirst: false) == [.text(0..<9), .enter], "ordinary plan has no preparation")
        var clearPosts = 0
        let missingCredential = attempt(initial: unknownEmpty, authorized: true, clearFirst: true, read: { false }, recheck: { unknownEmpty }, submit: { clearPosts += 1; return .submitted }, wait: { ready })
        check(missingCredential.0 == "credential_blocked" && clearPosts == 0, "credential refusal never clears")
        for stopAfter in [0, 1, 2, 3] {
            var postedPairs = 0
            let result = sendPairs(count: steps.count, validate: { postedPairs < stopAfter }, post: { _ in postedPairs += 1 })
            check(postedPairs == stopAfter && result == (stopAfter == 0 ? .refused : .partial), "stop during preparation or typing, no retry")
        }
        var changedSession = unknownEmpty; changedSession.sessionID = 10
        let raced = attempt(initial: unknownEmpty, authorized: true, clearFirst: true, read: { true }, recheck: { changedSession }, submit: { clearPosts += 1; return .submitted }, wait: { ready })
        check(raced.0 == "state_changed_before_input" && clearPosts == 0, "clear-first wrong session blocked")
        var invalidTarget = unknownEmpty; invalidTarget.targetOK = false
        check(policy(invalidTarget, authorized: true, clearFirst: true) != "ready", "clear-first never bypasses target checks")
        check(targetGuard(identity: true, uidMatches: true, pidMatches: true, role: "AXTextField", subrole: "AXSecureTextField", enabled: true, focused: false) != "verified", "lost focus blocked")
        var input = ready
        check(policy(ready, authorized: false) == "authorization_required", "explicit authorization")
        input.sessionOK = false
        check(policy(input, authorized: true) == "session_unverified", "wrong/logout/unknown console")
        input = ready; input.state = .unknown
        check(policy(input, authorized: true) == "lock_unknown", "unknown fails closed")
        input = ready; input.targetOK = false
        check(policy(input, authorized: true) == "password_target_unverified", "target absent")
        input = ready; input.ax = false
        check(policy(input, authorized: true) == "input_permission_missing", "AX refusal")
        input = ready; input.post = false
        check(policy(input, authorized: true) == "input_permission_missing", "post refusal")
        var reads = 0, submits = 0, waits = 0
        func run(_ start: Snapshot, credentialOK: Bool = true, before: Snapshot? = nil,
                 after: Snapshot? = nil, injection: InputResult = .submitted) -> (String, Bool) {
            attempt(initial: start, authorized: true, read: { reads += 1; return credentialOK },
                    recheck: { before ?? ready }, submit: { submits += 1; return injection },
                    wait: { waits += 1; return after ?? ready })
        }
        input = ready; input.state = .unlocked
        check(run(input).0 == "already_unlocked" && reads == 0 && submits == 0, "already unlocked no secret/input")
        check(run(ready, credentialOK: false).0 == "credential_blocked" && submits == 0, "locked/refused/missing keychain no retry")
        input = ready; input.sessionID = 10
        check(!consistent(ready, input), "stable identity changed")
        check(!consistent(Snapshot(), Snapshot()), "missing identity never matches")
        var invalidInitial = ready; invalidInitial.sessionOK = false
        check(!consistent(invalidInitial, ready), "unverified initial session")
        check(run(ready, before: input).0 == "state_changed_before_input" && submits == 0, "session race")
        input = ready; input.targetOK = false
        check(run(ready, before: input).0 == "state_changed_before_input" && submits == 0, "focus race")
        check(run(ready).0 == "confirmation_timeout_no_retry" && submits == 1 && waits == 1, "single attempt timeout")
        input = ready; input.state = .unlocked
        check(run(ready, after: input).0 == "unlocked_confirmed", "independent transition")
        input.sessionID = 10
        check(run(ready, after: input).0 == "session_changed_after_input", "other session cannot confirm")
        let waitBefore = waits
        check(run(ready, injection: .partial).0 == "partial_input_aborted_no_retry" && waits == waitBefore, "partial input no retry")
        check(run(ready, injection: .refused).1 == false, "no event refusal")
        var posted = 0
        check(sendPairs(count: 3, validate: { posted < 1 }, post: { _ in posted += 1 }) == .partial && posted == 1, "focus lost mid entry")
        check(sendPairs(count: 3, validate: { false }, post: { _ in posted += 1 }) == .refused && posted == 1, "no input ambiguous target")
        let synthetic = Array((String(repeating: "x", count: 19) + "😀abc").utf16)
        let ranges = unicodeRanges(synthetic)
        check(ranges[0].count == 19 && ranges.flatMap { Array(synthetic[$0]) } == synthetic, "UTF16 pair stays intact")
        check(exactBool(NSNumber(value: 1)) == nil && exactBool(kCFBooleanTrue) == true, "strict CFBoolean")
        check(!validPassword("") && !validPassword("x\ny") && !validPassword(String(repeating: "x", count: 257)), "input bounds")
        let receipt = Receipt(command: "unlock", result: "credential_blocked", lockState: .locked, submitted: false,
                              code: 2, sessionVerified: true, accessibility: true, postEvents: true,
                              passwordTargetVerified: true, credential: "requested_own_item")
        let json = String(data: try JSONEncoder().encode(receipt), encoding: .utf8)!
        check(!json.contains("SYNTHETIC_SECRET_42") && !json.contains("password\":"), "receipt has no secret field")
        let dir = FileManager.default.currentDirectoryPath + "/evidence/synthetic-lock"
        guard let first = acquireLock(directory: dir) else { fatalError("initial lock") }
        check(acquireLock(directory: dir) == nil, "concurrent exclusive lock")
        close(first)
        guard let second = acquireLock(directory: dir) else { fatalError("lock release") }
        close(second)
        check(true, "lock released after process/descriptor closes")
        print("PASS \(checks) targeted checks; synthetic only; no Keychain, AX probe, CGEvent, GUI or screen operations")
    }
}
