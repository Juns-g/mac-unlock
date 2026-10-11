# mac-unlock

[简体中文](README.zh-CN.md)

A native, on-demand helper for unlocking your own ordinary Mac lock screen, providing JSON receipts for local automation.

Runs only inside an already logged-in, verified console session. Does not include Bluetooth, network listeners, daemons, scheduled tasks, or wake support. Does not support FileVault, initial login, or logged-out sessions.

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

## Safety and limits

- Must verify the user's console UID, session, and lock state. The target must be the unique, same-user `loginwindow` process matching the expected bundle and binary, with a focused, enabled secure text field.
- Target and permission guards execute before retrieving credentials. Keychain refusal aborts without prompting or clearing the field.
- For unlocking, all input events are pre-allocated, directed to the verified PID, and guarded against the same field and session before each pair. Focus loss or partial input halts execution without retrying. Concurrent runs cannot interleave.
- Success requires independently confirming the session transitioned to unlocked; event posting alone is not confirmation. macOS event delivery is subject to system timing; this is not a privileged login plugin.
- Modifies no security settings, user passwords, FileVault states, or global permissions.
- Predecessor code verified an ordinary lock screen on macOS 27.2; this public branding build has passed only build, synthetic, and read-only checks without retesting credential entry under the new identity. Compatibility requires a verifiable target from the OS and local authorization.

## License and acknowledgment

MIT; see [LICENSE](LICENSE). Independently implemented; no upstream source files copied. The Keychain-to-CGEvent unlock flow was inspired by [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock).
