# mac-unlock

[简体中文](README.zh-CN.md)

A native, on-demand helper for unlocking your own ordinary Mac lock screen, providing JSON receipts for local automation.

Runs only inside an already logged-in, verified console session. Does not include Bluetooth, network listeners, daemons, scheduled tasks, or built-in wake support. Does not support waking a sleeping computer, FileVault, initial login, or logged-out sessions. Display preparation is a separate, explicitly authorized step described below.

## Build and install

Requires macOS and Swift from Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/Juns-g/mac-unlock.git
cd mac-unlock
sh build.sh
sh test.sh
sh install.sh
```

Installs `MacUnlock.app` to `~/Applications` and `mac-unlock` to `~/.local/bin`. Add `~/.local/bin` to your PATH or call it directly. The installer refuses to overwrite existing files. Build and test scripts accept an optional output directory.

The CLI launches the App via LaunchServices. Executing the binary directly from an agent host may cause macOS to attribute permissions to that host instead of the App. `--app /path/MacUnlock.app` is reserved for **read-only** build validation.

## One-time local setup

1. In System Settings → Privacy & Security, grant **MacUnlock.app** Accessibility and event-posting access (category names vary by macOS version). The tool inspects permissions without prompting.
2. While your session is unlocked, double-click the installed App or run `mac-unlock setup --local-user`. Enter your login password into the local masked prompt.

The password is stored exclusively in this tool's dedicated, non-synchronizing generic Keychain item, accessible only to the installed executable. Passwords are never accepted via arguments, environment variables, pipes, clipboards, or plaintext files. Agents must never run setup or launch the App without arguments.

Builds use an ad-hoc signature and the identifier `com.example.MacUnlock`. Rebuilding alters the code signature: re-authorize the App in System Settings, and rerun local setup if Keychain access is refused. Permissions and credentials are not inherited across installations. Keep the install path fixed.

## Usage

```sh
mac-unlock status
mac-unlock preflight --clear-first
mac-unlock unlock --dry-run --clear-first
# Run only with explicit user authorization for this machine action and field clearing:
mac-unlock unlock --authorize --clear-first
```

`status`, `preflight`, and `--dry-run` never read credentials or emit input. An `already_unlocked` receipt is a no-op and does not verify that permissions or credentials are ready. Invoking the CLI without arguments displays help; `mac-unlock --help` documents all commands, including explicitly authorized relocking.

By default, unlock requires a verified empty password field; if macOS hides the character count, the operation blocks. When explicitly authorized, `--clear-first` dispatches Command-A/Delete to the verified field before a single password submission. Target and credential guards run first; credential read failure aborts immediately without clearing. Receipts record observed empty-field evidence without claiming independent verification of clearing.

Exit codes: `0` confirmed result or no-op; `2` blocked; `3` input attempted or completion unknown; `64` invalid arguments. Failures or receipt timeouts must not trigger automatic retries.

### Prepare an idle display before unlocking

A focused, enabled secure text field can remain accessible to the OS while the lock-screen password interface is hidden. Therefore, a `ready` preflight is necessary but is not proof that the visible interface is ready to receive input. Never use a password submission to wake the display.

For an ordinary locked session, when the user has authorized unlocking **and** display preparation, macOS's system `caffeinate` command can briefly declare user activity without changing permanent power settings:

```sh
caffeinate -u mac-unlock preflight --clear-first
# Check the JSON: verified session, locked state, permissions, target, and ready.
# Separately verify that the intended lock-screen password control is actually visible.
# Only with explicit authorization for unlocking and clearing that verified field:
caffeinate -u mac-unlock unlock --authorize --clear-first
mac-unlock status
```

`caffeinate` prepares the display; it does not authenticate, prove the field is empty, bypass a guard, or resume a computer from system sleep. Here its assertion lasts for the invoked command; macOS ignores `-t` when a utility is supplied, so adding `-t 45` would not impose a 45-second deadline. The helper still performs its own target, session, permission, credential, and single-attempt checks. Read the App's JSON receipt, not merely the launcher's exit status. `unlocked_confirmed` followed by a fresh `status` showing the same verified session unlocked is the success criterion. An `already_unlocked` result is still only a no-op.

If an attempt fails, stop rather than automatically clearing or resubmitting. Read-only system logs containing `View is hidden`, `userIsActiveCheck` returning `0`, or `_wakeForIncomingMessage` followed by `don't start the Unlock` are clues that the interface was not ready; they do not prove an incorrect password. A new attempt requires a fresh, informed user request, a corrected and independently verified prerequisite, and a new preflight—not an unchanged retry loop. Do not print or collect password contents while investigating.

This preparation sequence succeeded with the previously validated native implementation after an idle-display failure. It does not change the public App or its identity, and does not claim that this public branding build has passed a new credential-entry test.

## Safety and limits

- Must verify the user's console UID, session, and lock state. The target must be the unique, same-user `loginwindow` process matching the expected bundle and binary, with a focused, enabled secure text field.
- Target and permission guards execute before retrieving credentials. Keychain refusal aborts without prompting or clearing the field.
- For unlocking, all input events are pre-allocated, directed to the verified PID, and guarded against the same field and session before each pair. Focus loss or partial input halts execution without retrying. Concurrent runs cannot interleave.
- Success requires independently confirming the session transitioned to unlocked; event posting alone is not confirmation. macOS event delivery is subject to system timing; this is not a privileged login plugin.
- Modifies no security settings, user passwords, FileVault states, or global permissions.
- Predecessor code verified an ordinary lock screen on macOS 27.2; this public branding build has passed only build, synthetic, and read-only checks without retesting credential entry under the new identity. Compatibility requires a verifiable target from the OS and local authorization.

## License and acknowledgment

MIT; see [LICENSE](LICENSE). Independently implemented; no upstream source files copied. The Keychain-to-CGEvent unlock flow was inspired by [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock).
