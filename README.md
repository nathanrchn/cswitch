# Cswitch

A small native macOS menu bar app for Claude Code accounts, on your Mac and Linux devices over SSH. SwiftUI and AppKit; no third-party packages, Claude extension, server daemon, telemetry, or background inference.

## Build and run

Requires macOS 14+ and Xcode 26 or newer. On macOS 26 and newer, the interface uses SwiftUI's native Liquid Glass controls and hover surfaces. Older systems use standard bordered controls and material surfaces. The menu panel keeps the system popover background instead of painting over it.

```sh
./scripts/build.sh
open dist/Cswitch.app
```

The build is ad-hoc signed for local development. Set `CSWITCH_SIGNING_IDENTITY` to your own signing identity for distribution. This is not a notarized distribution build.

To preview the interface with fictional accounts and no credential, filesystem, or network access:

```sh
open dist/Cswitch.app --args --demo --preview
```

## Use

1. Click **Add account**, enter a label, then **Sign in**. Cswitch starts an OAuth PKCE flow in the background and opens Claude's authorization page in its own private sign-in window. No Terminal app or CLI sign-in process is launched.
2. Complete the browser sign-in. The localhost callback returns to Cswitch and saves the account automatically, without changing any device's current account. Repeat once per account, not once per device. You can also import an existing file-based login from the selected device.
3. Click **Switch** beside an account to apply it to **all saved devices**, including this Mac and `amdcluster`. The `amdcluster` SSH alias uses your existing SSH config, key, port and jump host. An already installed Claude Code can receive its first login this way without an interactive sign-in on that device.
4. Cswitch reads each target first, preserves verified outgoing file logins, validates the chosen account once, then applies the same login to the devices concurrently. Expired or inconsistent outgoing file logins do not replace existing account backups. **Selected** appears when every saved device reports the same configured account. Cswitch restores the last observed selections on launch and rechecks the devices. **Last selected** identifies a cached selection while a device is unavailable or not yet checked; a partial **1/2** badge shows when devices differ. The **All devices** menu names each device's account. On the Mac, account metadata is displayed even if Claude stores its credential outside the fallback file. Missing organization metadata is matched by account UUID only when one saved account is unambiguous. This display logic does not relax credential validation or inspect a running Claude session or its Keychain. Restart Claude Code and use `/status` to confirm which account it chose. Cswitch's switch uses no biometric or credential-store unlock.
5. Use the **…** button on an account to rename it, apply its saved login again, or **Delete saved account…** from the global list. Deleting a saved account removes its local secret file and cached usage; it does not revoke existing logins or delete conversations on any device. Right-click exposes the same actions.

Add other Linux devices through **… → Add SSH device…**. They need Python 3, Claude Code, and a working passwordless SSH connection. Host keys must already be trusted; Cswitch never disables host-key verification. No helper is installed on the server: a short Python script runs over the SSH connection.

Accounts and labels are shared across all devices. The **All devices** menu lists connectivity and configured accounts; account switching always targets the whole saved device list. The add-account sheet has an **Import from** picker for importing an existing file login. Subscription usage is fetched once per global account and is not added again for every device.

A multi-device switch is not an atomic transaction across machines. If a device is unavailable or changes its login during the operation, other successful devices keep their new selection. The error lists failed devices and the successful count. Click **Switch** again to retry; matching up-to-date devices are skipped. No switch is queued to run silently when an offline server reconnects. A global failure before the apply stage leaves all target credentials unchanged.

Earlier per-device account records are merged by account UUID and organization. Labels and cached usage are retained. Credentials saved in older Keychain versions are deliberately not read or migrated; sign in once again to create the new file-based copy, or import an existing file-based login from a Linux device. Old system credential entries are left untouched.

## Sign-in window

Cswitch uses a native window with WebKit and a fresh nonpersistent website data store for each sign-in. Its temporary browser session is independent of Safari and your other accounts. The window closes and releases its browser session when the login finishes or you cancel. No Safari automation, Accessibility permission or Automation permission is needed. Closing the menu bar popover does not cancel an open sign-in window.

Use Claude's email sign-in in this window. Google prohibits embedded OAuth browsers, so Google sign-in is blocked with an explanation instead of disguising the browser or opening Safari automatically. Other SSO providers may also require an external browser. For those cases, **Copy sign-in link** lets you open a private browser yourself while Cswitch waits for the callback. SSO popup windows that support WebKit stay within Cswitch and share only the current sign-in session.

The sign-in window and add-account sheet offer **Copy sign-in link**. If the browser callback cannot finish, paste its localhost URL or authorization code into the sheet. Cancel stops the listener and any pending token exchange. Cswitch validates the OAuth state on callbacks received from the embedded browser and from the listener bound only to `127.0.0.1:53692`. Sign-in expires after five minutes. A busy callback port produces an error instead of opening a public listener or reusing another login flow.

## Shared-login renewal

Claude Code OAuth credentials can be transferred, which avoids an interactive login on every device. This uses the same unofficial credential integration as account switching; it is not a vendor-supported account-sync service and cannot promise never to require signing in again.

Before applying an account, Cswitch checks its known devices for a newer selected credential and keeps the newest expiry generation in its local secret file. Offline replicas are tolerated while the saved login is usable. If a selected or unreachable device might own a newer generation, Cswitch refuses to refresh an expired copy blindly; open Claude Code there to let it renew, then refresh Cswitch. This applies to both Mac and Linux file logins. Otherwise, Cswitch can renew an inactive saved login. Background usage refresh saves recovered credentials to Cswitch's backups without rewriting the Mac's credential files or settings.

Independent Claude processes on separate machines do not share a distributed refresh lock. Simultaneous renewal, revocation, or a stale replica can still invalidate a copy. Use **Apply saved login again…** to resend the recovered login to all devices, or sign in once and save it again if the shared login is no longer valid. Reapplying a saved login is explicit; Cswitch does not push credentials during background refresh or require an always-running server agent.

## Shared configuration

Each device keeps its normal shared `~/.claude` directory. Both Mac and Linux switches replace `claudeAiOauth` in `~/.claude/.credentials.json` and `oauthAccount` in `~/.claude.json` (or the existing legacy config path). They preserve the rest of those files, including MCP credentials and unrelated account settings. A local Mac switch also removes the old `env.CLAUDE_CODE_OAUTH_TOKEN` override from `~/.claude/settings.json`. Other environment settings are preserved; when no override is present, settings.json is left untouched. Cswitch supports the default profile; custom remote `CLAUDE_CONFIG_DIR` profiles and symlinked state files are rejected rather than guessed.

**Migrating from the earlier Mac token mode:** after installing this version, click **Switch** for the desired saved account. This applies the full file login on every device and removes the old global Mac token override in the same local rollback-protected operation. Existing saved accounts do not need to be deleted or added again. Restart running Claude Code sessions afterwards. Nothing is migrated automatically when Cswitch opens.

**macOS limitation:** Claude Code normally prefers Keychain and documents the credential file as a fallback. Cswitch does not disable, read, replace or delete that Keychain entry. Writing the file therefore cannot guarantee that Claude will use it while a different Keychain login is available. If `/status` still shows the old account, the file switch has not controlled that session's authentication. The app's **Selected** marker reflects configured account metadata, not verification of the credential a running Claude process uses. There is no claim that this forces Claude into a supported file-only storage mode.

There is one selected account per device. Running Claude sessions can cache credentials: restart/resume them after switching if you need the new account immediately. Cswitch never kills a session. Existing environment overrides, such as `ANTHROPIC_API_KEY`, can take precedence over the subscription login; use a normal subscription-authenticated Claude shell.

## Usage

- Separate 5-hour, weekly, and Fable weekly bars, with reset countdowns.
- Missing limits show **Unknown**, never a fabricated 0%.
- Cached usage stays visible during network failures, with the error shown.
- Refreshes on opening when the last check is older than a minute, and every three minutes while the app is running. Rate-limit responses delay retries.
- The menu shows each account's usage and marks the account selected across every saved device. Device account metadata and last-check times are cached across launches, with live observations taking precedence and unavailable devices marked as last known. On the Mac, this is the configured account, not verification of a running Claude session. Successful switches do not add a notification row; errors remain visible when an action fails.
- Shared logins are recovered from known devices before renewal as described above. New credentials are saved to their private files before transfer or use. A selected device being offline does not stop usage checks for usable saved accounts.

Claude's usage endpoint and credential internals are unofficial integration points. The parser supports legacy session/weekly fields and model-scoped `limits[]` entries. An upstream change may require an update. Numeric limits depend on what the subscription exposes.

## Token history

The bottom section combines recorded Claude Code usage from this Mac and all saved Linux SSH devices. It defaults to **7 days**; **7 days** and **30 days** zoom into daily bars with date labels and a scale based on the selected range. **All time** keeps the daily heatmap for the past year and all-time totals. Below the total, input, output and cached token counts are always visible, with cache reads and cache writes listed separately. Hover a bar or heatmap square for an immediate detail card with the date, exact token counts, input/output/cache breakdown, request count and estimated API cost. Hover a summary count for its exact value. The **estimated API cost** is in USD; hover it for pricing details. Total tokens include input, output, cache reads and cache writes. Historical records span all accounts; transcripts do not reliably identify the subscription used, so old activity is never assigned to whichever account is selected now.

The native Mac reader and a read-only SSH helper scan `~/.claude/projects/**/*.jsonl`, including subagent sessions. Only assistant usage metadata is retained: response IDs, timestamps, model IDs and token counts. Prompts, responses and tool arguments are not transmitted from the server or saved in Cswitch's history cache. Repeated streaming updates and transcript copies across devices are deduplicated by message ID, or request ID when no message ID exists, retaining the most complete usage record.

The first scan can take longer on large histories; later scans read only files whose size or modification date changed. History refresh runs separately from account actions. The Mac keeps a private `0600` cache at `~/Library/Application Support/Cswitch/history.json`, including counters already seen in logs that Claude later deletes. Activity deleted before the first scan, claude.ai web chats, and devices not added to Cswitch cannot be recovered. An empty heatmap cell means no recorded tokens in the available history, not proof of no account activity. Offline devices keep their cached history and are marked **cached / incomplete**; unreadable records are also indicated.

Prices use standard first-party [API list rates](https://platform.claude.com/docs/en/about-claude/pricing), checked **2026-10-19**. They are API-equivalent estimates, not subscription charges or reconstructed bills. Cache writes without a recorded TTL produce a range between 5-minute and 1-hour pricing. Unsupported models retain their token counts but are excluded from the cost, which is marked as a partial estimate. Historical price changes, regional premiums, tool charges, taxes and negotiated discounts are not reconstructed. Supported fast-mode flags and Haiku 5.5's prompt-length price tier are accounted for when present in usage metadata.

## Credential storage and switching

Saved OAuth credentials are plaintext files at `~/Library/Application Support/Cswitch/secrets/<account-id>.json`, with mode `0600`, in a directory with mode `0700`. They are readable by your macOS user; they are not hardware-encrypted or stored in Keychain. The JSON index at `~/Library/Application Support/Cswitch/accounts.json` contains global labels, device aliases, account identity, known replica devices, cached usage and last observed device selections with check times, not tokens.

Cswitch contains no Keychain access, biometric authentication, `security` subprocess, or automatic system-credential migration.

On both Mac and Linux, Cswitch writes the full OAuth credential (access token, refresh token and available subscription metadata) to `~/.claude/.credentials.json` with mode `0600`. It does not inject an environment token or API key. On the Mac, this is Claude's file-fallback format, subject to the Keychain limitation above. Restart Claude Code after applying an account, and confirm its identity with `/status`. Credentials travel over SSH stdin or HTTPS to Anthropic, never process arguments or logs.

Switches coordinate with Claude's credential/config directory locks. Before switching, the outgoing file credential is saved; an exact state fingerprint prevents overwriting a concurrent refresh. Failed local writes roll back earlier writes to the credential, settings and account files. A process/power failure between files is not a fully atomic transaction; check/reapply if the app cannot verify a switch after interruption. Unreachable-device errors never claim that a switch succeeded.

## Verification

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
python3 -m unittest discover -s Tests -p 'test_remote.py' -v
```

Tests use temporary synthetic credentials, covering malformed usage responses, Fable limits, duplicate-account aggregation, state preservation, write rollback, rejected SSH input, symlink rejection and concurrent credential changes. Tests do not access a real Keychain account or switch a real device.

A read-only check of the actual bundled SSH helper is available:

```sh
dist/Cswitch.app/Contents/MacOS/Cswitch --check-device amdcluster
```

This reads remote account metadata, checks the Claude executable, and does not read or change credentials. Live credential transfer/switch must be exercised interactively with saved accounts.

## References

The minimal scope is informed by [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker). Integration behavior was checked against [Anthropic authentication documentation](https://code.claude.com/docs/en/authentication), [CodexBar's Claude usage notes](https://github.com/steipete/CodexBar/blob/main/docs/claude.md), and [claude-swap's credential-lock protocol](https://github.com/realiti4/claude-swap/blob/main/src/claude_swap/claude_locks.py). This is an independent implementation.
