# Cswitch

A small native macOS menu bar app for Claude Code accounts, on your Mac and Linux devices over SSH. SwiftUI and AppKit; no third-party packages, Claude extension, server daemon, telemetry, or background inference.

## Build and run

Requires macOS 14+ and Xcode 26 or newer. The menu panel keeps the system popover background and lays light cards over it, with a terracotta accent taken from the app icon; it follows the system light or dark appearance.

```sh
./scripts/build.sh
open dist/Cswitch.app
```

The build is ad-hoc signed for local development. Set `CSWITCH_SIGNING_IDENTITY` to your own signing identity for distribution. This is not a notarized distribution build.

To preview the interface with fictional accounts and no credential, filesystem, or network access:

```sh
open dist/Cswitch.app --args --demo --preview
```

Add `--mixed` to preview devices that disagree, an offline device and an unsaved login. `Cswitch --check-device local` (or an SSH alias) prints what Claude Code reports on that device without reading or changing credentials.

## Use

1. Click **Add account**, enter a label, then **Sign in**. Cswitch starts an OAuth PKCE flow in the background and opens Claude's authorization page in its own private sign-in window. No Terminal app or CLI sign-in process is launched.
2. Complete the browser sign-in. The localhost callback returns to Cswitch and saves the account automatically, without changing any device's current account. Repeat once per account, not once per device. You can also import an existing login from the selected device, including Claude's active Mac Keychain login.
3. Click **Switch** beside an account to apply it to **all saved devices**, including this Mac and `amdcluster`. The `amdcluster` SSH alias uses your existing SSH config, key, port and jump host. An already installed Claude Code can receive its first login this way without an interactive sign-in on that device.
4. Cswitch reads each target first, preserves verified outgoing logins, validates the chosen account once, then applies the same login to the devices concurrently. On this Mac it updates Claude's active Keychain login and fallback file together. The banner at the top says whether every device uses the same account (**In sync**) or not (**Out of sync**), and the **Devices** list shows each account, Claude Code version and connection state. `claude auth status --json` supplies display metadata; it can combine configured labels with another credential's subscription, so a matching email alone is not proof of a switch. Known plan conflicts are shown instead of claiming **In sync**. Switch verification checks the complete Keychain and file credentials against the server-verified selected login. Older Claude releases without the auth command fall back to configuration metadata; `--help` is checked first to avoid sending a prompt. Offline devices retain their last known account, marked with a dashed outline. An account is **Active** when every device resolves to it; partial selections offer **Switch all**. Unsaved logins offer **Save account**. Restart running Claude Code sessions after switching. Cswitch adds no fingerprint, password or confirmation step of its own. macOS may request permission to access Claude's Keychain entry; **Always Allow**, when offered, remembers access for the application.
5. Use the **…** button on an account to rename it, apply its saved login again, or **Delete saved account…** from the global list. Deleting a saved account removes its local secret file and cached usage; it does not revoke existing logins or delete conversations on any device. Right-click exposes the same actions.

Add other Linux devices through **… → Add SSH device…**. They need Python 3, Claude Code, and a working passwordless SSH connection. Host keys must already be trusted; Cswitch never disables host-key verification. No helper is installed on the server: a short Python script runs over the SSH connection.

Accounts and labels are shared across all devices. Hover a device for connection errors and its last check time; account switching always targets the whole saved device list. The add-account sheet lists device logins with **Import** for unsaved accounts. Subscription usage is fetched once per global account and is not added again for every device.

A multi-device switch is not an atomic transaction across machines. If a device is unavailable or changes its login during the operation, other successful devices keep their new selection. The error lists failed devices and the successful count. Click **Switch** again to retry; matching up-to-date devices are skipped. No switch is queued to run silently when an offline server reconnects. A global failure before the apply stage leaves all target credentials unchanged.

Earlier per-device account records are merged by account UUID and organization. Labels and cached usage are retained. Old Cswitch-specific Keychain vault entries are not migrated; saved backups remain private files. Only Claude Code's active Keychain entry is used for a Mac switch or import.

## Sign-in window

Cswitch uses a native window with WebKit and a fresh nonpersistent website data store for each sign-in. Its temporary browser session is independent of Safari and your other accounts. The window closes and releases its browser session when the login finishes or you cancel. No Safari automation, Accessibility permission or Automation permission is needed. Closing the menu bar popover does not cancel an open sign-in window.

Use Claude's email sign-in in this window. Google prohibits embedded OAuth browsers, so Google sign-in is blocked with an explanation instead of disguising the browser or opening Safari automatically. Other SSO providers may also require an external browser. For those cases, **Copy sign-in link** lets you open a private browser yourself while Cswitch waits for the callback. SSO popup windows that support WebKit stay within Cswitch and share only the current sign-in session.

The sign-in window and add-account sheet offer **Copy sign-in link**. If the browser callback cannot finish, paste its localhost URL or authorization code into the sheet. Cancel stops the listener and any pending token exchange. Cswitch validates the OAuth state on callbacks received from the embedded browser and from the listener bound only to `127.0.0.1:53692`. Sign-in expires after five minutes. A busy callback port produces an error instead of opening a public listener or reusing another login flow.

## Shared-login renewal

Claude Code OAuth credentials can be transferred, which avoids an interactive login on every device. This uses the same unofficial credential integration as account switching; it is not a vendor-supported account-sync service and cannot promise never to require signing in again.

Before applying an account, Cswitch checks its known devices for a newer selected credential and keeps the newest expiry generation in its local secret file. Offline replicas are tolerated while the saved login is usable. If a selected or unreachable device might own a newer generation, Cswitch refuses to refresh an expired copy blindly; open Claude Code there to let it renew, then refresh Cswitch. This applies to Mac Keychain and Linux file logins. Otherwise, Cswitch can renew an inactive saved login. Background reads suppress Keychain permission dialogs and leave saved accounts usable when access is unavailable. Background usage refresh saves recovered credentials to Cswitch's backups without rewriting the Mac's Keychain login, credential files or settings.

Independent Claude processes on separate machines do not share a distributed refresh lock. Simultaneous renewal, revocation, or a stale replica can still invalidate a copy. Use **Apply saved login again…** to resend the recovered login to all devices, or sign in once and save it again if the shared login is no longer valid. Reapplying a saved login is explicit; Cswitch does not push credentials during background refresh or require an always-running server agent.

## Shared configuration

Each device keeps its normal shared `~/.claude` directory. Switches replace `claudeAiOauth` in `~/.claude/.credentials.json` and `oauthAccount` in `~/.claude.json` (or the existing legacy path). On macOS, they also replace `claudeAiOauth` in Claude's `Claude Code-credentials` login Keychain entry. Unrelated fields in each store, including MCP credentials, are preserved. Claude's cached subscription usage is cleared so another account's limits are not retained under the new labels. A Mac switch removes the old `env.CLAUDE_CODE_OAUTH_TOKEN` override from `~/.claude/settings.json`, preserving other settings and leaving that file untouched when no override exists. Cswitch supports the default profile; custom Mac credential/config directories, custom remote profiles and symlinked state files are rejected rather than guessed.

**Migrating from earlier Mac file/token modes:** click **Switch** for the desired saved account. This applies the full login to Keychain and the fallback file on the Mac, updates Linux devices, and removes the old global Mac token override. Existing saved accounts do not need to be added again. Restart running Claude Code sessions afterwards. Nothing is migrated automatically when Cswitch opens.

**macOS Keychain permission:** Cswitch uses native Security APIs in its own process, so macOS attributes the access request to Cswitch. Existing entries are updated in place to preserve their access permissions and **Always Allow** grants. A new entry trusts Cswitch and `/usr/bin/security`, the helper Claude itself uses, rather than all applications. No Touch ID check or extra Cswitch authorization precedes switching. macOS still controls permission prompts and unlocking. The development build is ad-hoc signed, so rebuilding it may require granting access again; use a stable signing identity for releases.

There is one selected account per device. Running Claude sessions can cache credentials: restart/resume them after switching if you need the new account immediately. Cswitch never kills a session. Existing environment overrides, such as `ANTHROPIC_API_KEY`, can take precedence over the subscription login; use a normal subscription-authenticated Claude shell.

## Usage

- Separate 5-hour, weekly, and Fable weekly bars, with reset countdowns.
- Missing limits show **Unknown**, never a fabricated 0%.
- Cached usage stays visible during network failures, with the error shown.
- Refreshes on opening when the last check is older than a minute, and every three minutes while the app is running. Rate-limit responses delay retries.
- The menu shows each account's usage and marks the account active across every saved device. Device logins and last-check times are cached across launches, with live observations taking precedence and unavailable devices marked as last known. A switch shows progress per device; errors remain visible when an action fails.
- Usage refreshes for all accounts run in parallel and no longer block **Switch**; a switch started during a refresh waits for it to finish.
- Shared logins are recovered from known devices before renewal as described above. New credentials are saved to their private files before transfer or use. A selected device being offline does not stop usage checks for usable saved accounts.

Claude's usage endpoint and credential internals are unofficial integration points. The parser supports legacy session/weekly fields and model-scoped `limits[]` entries. An upstream change may require an update. Numeric limits depend on what the subscription exposes.

## Token history

The **Token usage** card combines recorded Claude Code usage from this Mac and all saved Linux SSH devices. Click its title to collapse it to a one-line total; the choice is remembered. It defaults to **7D**; **7D** and **30D** zoom into daily bars with date labels and a scale based on the selected range. **All** keeps the daily heatmap for the past year and all-time totals. Below the total, input, output and cached token counts are always visible, with cache reads and cache writes listed separately. Hover a bar or heatmap square to show that day's tokens, estimated API cost, input/output/cache breakdown and request count in place of the period totals, so nothing covers the chart. Hover a number for its exact value. The **estimated API cost** is in USD; hover it for pricing details. Total tokens include input, output, cache reads and cache writes. Historical records span all accounts; transcripts do not reliably identify the subscription used, so old activity is never assigned to whichever account is selected now.

The native Mac reader and a read-only SSH helper scan `~/.claude/projects/**/*.jsonl`, including subagent sessions. Only assistant usage metadata is retained: response IDs, timestamps, model IDs and token counts. Prompts, responses and tool arguments are not transmitted from the server or saved in Cswitch's history cache. Repeated streaming updates and transcript copies across devices are deduplicated by message ID, or request ID when no message ID exists, retaining the most complete usage record.

The first scan can take longer on large histories; later scans read only files whose size or modification date changed. History refresh runs separately from account actions. The Mac keeps a private `0600` cache at `~/Library/Application Support/Cswitch/history.json`, including counters already seen in logs that Claude later deletes. Activity deleted before the first scan, claude.ai web chats, and devices not added to Cswitch cannot be recovered. An empty heatmap cell means no recorded tokens in the available history, not proof of no account activity. Offline devices keep their cached history and are marked **cached / incomplete**; unreadable records are also indicated.

Prices use standard first-party [API list rates](https://platform.claude.com/docs/en/about-claude/pricing), checked **2026-10-19**. They are API-equivalent estimates, not subscription charges or reconstructed bills. Cache writes without a recorded TTL produce a range between 5-minute and 1-hour pricing. Unsupported models retain their token counts but are excluded from the cost, which is marked as a partial estimate. Historical price changes, regional premiums, tool charges, taxes and negotiated discounts are not reconstructed. Supported fast-mode flags and Haiku 5.5's prompt-length price tier are accounted for when present in usage metadata.

## Credential storage and switching

Saved OAuth credentials are plaintext files at `~/Library/Application Support/Cswitch/secrets/<account-id>.json`, with mode `0600`, in a directory with mode `0700`. They are readable by your macOS user; they are not hardware-encrypted or stored in Keychain. The JSON index at `~/Library/Application Support/Cswitch/accounts.json` contains global labels, device aliases, account identity, known replica devices, cached usage and last observed device selections with check times, not tokens.

Cswitch accesses only Claude's active login Keychain entry through native Security APIs, with no biometric authentication or `security` subprocess of its own. Imports and outgoing Mac backups verify the actual token owner with Claude, rather than trusting possibly stale account labels. Opening the app does not migrate accounts into Cswitch's vault.

On both Mac and Linux, Cswitch writes the full OAuth credential (access token, refresh token and available subscription metadata) to `~/.claude/.credentials.json` with mode `0600`. The Mac's active Keychain entry receives the same full login. Cswitch does not inject an environment token or API key. Restart Claude Code after applying an account and confirm `/status` and `/usage`. Credentials travel through native Security APIs, SSH stdin or HTTPS to Anthropic, never process arguments or logs.

Switches coordinate with Claude's credential/config directory locks. An exact fingerprint includes the Keychain entry as well as the files, rejecting concurrent changes. A denied Keychain write leaves the files untouched; later write or verification failures restore the original Keychain data and files. Rollback does not overwrite a Keychain login that another process changed meanwhile, and reports incomplete recovery. A process/power failure between stores is not fully atomic; check/reapply if interrupted. Unreachable-device errors never claim success.

## Verification

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
python3 -m unittest discover -s Tests -p 'test_remote.py' -v
```

Tests use temporary synthetic credentials and an in-memory Keychain double, covering full login swaps, permission denial, creation, preservation of unrelated state, rollback, concurrent refreshes, stale usage clearing and misleading email/plan combinations, alongside usage parsing and SSH validation. Tests do not access a real Keychain account or switch a real device.

A read-only check of the actual bundled SSH helper is available:

```sh
dist/Cswitch.app/Contents/MacOS/Cswitch --check-device amdcluster
```

This reads remote account metadata, checks the Claude executable, and does not read or change credentials. Live credential transfer/switch must be exercised interactively with saved accounts.

## References

The minimal scope is informed by [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker). Integration behavior was checked against [Anthropic authentication documentation](https://code.claude.com/docs/en/authentication), [CodexBar's Claude usage notes](https://github.com/steipete/CodexBar/blob/main/docs/claude.md), and [claude-swap's credential-lock protocol](https://github.com/realiti4/claude-swap/blob/main/src/claude_swap/claude_locks.py). This is an independent implementation.
