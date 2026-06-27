# cc-usage-bar — Codex Integration Notes

Development summary for the fork that extends `cc-usage-bar` to show **Codex usage
alongside Claude** in one stacked menu-bar popover. Captured from the implementation
session (verified against codex 0.142.3, 2026-06-27).

---

## 1. Goal & Chosen UX

The app shows Claude Code usage by opening a PTY, running `claude` via a login
shell, sending `/usage`, capturing the terminal output, and rendering it raw (no
structured parsing). The fork extends this to **also show Codex usage**.

**Chosen display model: "Both at once (stacked)"** — one menu-bar icon, one
popover with Claude on top and Codex below. Each provider runs its own CLI
session and renders its own raw output. Display stays raw (no parsing into native
bars).

Three follow-up issues were reported after the first build, all now fixed:
1. The built `.app` had no icon (`AppIcon.appiconset` wasn't making it into `./build`).
2. Wanted caching / debounce / background refresh (usage was empty for the first
   few seconds after the popover appeared; Codex is much slower than Claude).
3. Codex didn't work — `Error: Timed out (stage: waitingForBanner)`.

---

## 2. Key Technical Concepts

- macOS menu-bar app: `NSStatusItem` + `NSPopover` + SwiftUI via
  `NSHostingController`, `LSUIElement=YES` accessory app (no Dock icon).
- PTY pseudo-terminal: `posix_openpt`, `grantpt`, `unlockpt`, `ptsname`,
  `fork()` via `dlsym`, `setsid`, `TIOCSCTTY`, `dup2`,
  `execv("/bin/zsh", ["-l","-c","<cmd>"])`.
- `DispatchSourceRead` reads PTY output in 4096-byte chunks.
- State machine: `waitingForBanner` → `waitingForPrompt` → `waitingForResult` →
  `capturing`.
- `ANSIParser`: reconstructs a virtual screen from ANSI escapes; scrolls on
  newline at the bottom row.
- **SIGWINCH redraw trick** (PTY resize `cols → cols-1 → cols`) forces
  diff-rendering TUIs (Ink, ratatui) to repaint every cell.
- `stripANSI` must handle OSC, CSI, and ESC+char.
- **Codex** (Rust / ratatui / crossterm) renders char-by-char with per-char
  cursor positioning; **Claude** (Ink) renders contiguously.
- Swift concurrency: `@MainActor` isolation; project uses `SWIFT_VERSION = 5.0`
  and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Type-check standalone with
  `-swift-version 5 -default-isolation MainActor`.
- Building without Xcode: `swiftc` compile + manual `.app` bundle + `Info.plist`
  + `iconutil` (icns) + `codesign --force --sign - --entitlements`.
- `os.Logger` (subsystem `com.ccusagebar`) info/debug logs are memory-only — use
  live `log stream --process CCUsageBar --level debug` (the `--predicate` form
  gets mangled by the shell wrapper).
- `PBXFileSystemSynchronizedRootGroup` auto-discovers new `.swift` files (no
  pbxproj edit needed).

---

## 3. The Decisive Codex Lesson

**String detection does not work for Codex under the GUI app.** Codex positions
every character with its own cursor escape (`O p e n A I   C o d e x`) and
aggressively scrolls, so the welcome-box banner never appears as a contiguous (or
even whitespace-compacted) substring in the scan buffer once it runs concurrently
with Claude. The `ANSIParser` screen reconstruction produced mangled
one-char-per-line output, and the banner scrolled off entirely.

**Fix: Codex is driven on timers, not string triggers.**
- `bootDelay` (~3.5s): after launch, just wait, then send `/status` — no banner match.
- `submitDelay` (~0.6s): then press Enter.
- `captureWindow` (~4s): set stage = capturing immediately, SIGWINCH-redraw at
  ~40% through, finalize at the end. The redraw forces a clean full frame; parsing
  the captured bytes and trimming the `╭ … ╰` box containing `5h limit:` yields the
  clean status box.

Claude keeps the original string-based flow (banner → echo → result + idle);
`bootDelay` / `captureWindow` are `nil` for it.

Verified Codex output:

```
╭──────────────────────────────────────╮
│  >_ OpenAI Codex (v0.142.3)           │
│  5h limit:    [███░░░░] 12% left       │
│  Weekly limit:[████████░] 60% left     │
│  Credits:     143 credits              │
╰──────────────────────────────────────╯
```

---

## 4. Files Changed

### `CCUsageBar/CCUsageBar/Provider.swift` (NEW)
Core abstraction holding all provider-specific config:

```swift
struct LaunchGate { let trigger: String; let send: String }
enum Workdir { case freshTemp; case stable(String) }
enum TrimStrategy { case fromMarker(String); case boxContaining(String) }
struct Provider {
    let id, displayName, command, usageCommand: String
    let ptyRows, ptyCols: UInt16
    let bannerPattern: String
    let gates: [LaunchGate]
    let commandEcho: String?
    let submitDelay: TimeInterval
    let resultTrigger: String
    let bootDelay: TimeInterval?      // timed launch (Codex)
    let captureWindow: TimeInterval?  // timed capture (Codex)
    let rateLimitTrigger: String?
    let setupTriggers: [String]
    let needsSigwinchRedraw: Bool
    let trim: TrimStrategy
    let workdir: Workdir
    let reusesSession: Bool
}
```

- **`.claude`**: `claude` / `/usage`, 24×68, banner `Claude Code v\d+`, gate
  `("Quick safety check", "\r")`, `commandEcho "/usage"`, `submitDelay 0`,
  `resultTrigger "Current session"`, `bootDelay nil`, `captureWindow nil`,
  rateLimit `rate_limit_error`, setup `["Welcome to Claude Code", …]`,
  sigwinch `true`, trim `.fromMarker("Current session")`, workdir `.freshTemp`,
  `reusesSession true`.
- **`.codex`**: `codex` / `/status`, 42×68, banner `OpenAI Codex`, gates
  `("trust the contents of this directory", "\r")` &
  `("Update available", Esc)`, `commandEcho nil`, `submitDelay 0.6`,
  `resultTrigger "5h limit:"`, `bootDelay 3.5`, `captureWindow 4.0`,
  rateLimit `nil`, setup `["Sign in with ChatGPT", "Not logged in", "codex login"]`,
  sigwinch `true`, trim `.boxContaining("5h limit:")`,
  workdir `.stable("~/Library/Application Support/CCUsageBar/codex-workdir")`,
  `reusesSession false`.
- `TrimStrategy.apply(to:)`: `.fromMarker` returns from the marker's line to the
  end; `.boxContaining` walks up to the nearest `╭` and down to the nearest `╰`,
  returning that inclusive box.

### `CCUsageBar/CCUsageBar/UsageViewModel.swift` (HEAVILY MODIFIED)
- Added `let provider: Provider` + `init(provider:)`; replaced every hardcoded
  Claude literal with `provider.*`.
- **Caching / stale-while-revalidate**: `lastLoaded`, `lastFetch`, `isFetching`,
  `minRefreshInterval = 60`. `run(force:)` shows cached immediately, returns early
  if fetching or fresh; `startFetch()` does the real work.
- `cancelQuery()` is the single place that clears `isFetching`. `finalize()`
  checks `guard isFetching` **before** `cancelQuery()`, caches the result, and
  tears down if `!reusesSession`. `handleTimeout` shows stale cache if available.
- `stripANSI` fixed to strip OSC:
  `\u{1B}\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)|\u{1B}\[[^@-~]*[@-~]|\u{1B}[^\[]`
  (OSC | CSI | ESC+char). Codex spams OSC title updates that were flooding the buffer.
- Read-handler matching captures `buf` (scanBuffer) and `cbuf`
  (whitespace-compacted) locals first (avoids touching main-actor state from the
  nonisolated read context), then uses `has(_:)` / `hasRegex(_:)`.
- Banner check gated by `bootDelay == nil`; result check + idle reschedule gated
  by `captureWindow == nil`.
- `launchSession` uses `provider.ptyRows/Cols`, `resolvedWorkdir()`,
  `strdup(provider.command)`, and schedules a boot timer when `bootDelay` is set.
- `submitUsageCommand`: timed path (Codex) sets stage = capturing, sends `\r`
  after `submitDelay`, then `beginTimedCapture`. Else the `commandEcho` path (Claude).
- `beginTimedCapture(queryId:window:)`: schedules `forceRedraw()` at `window*0.4`
  and `finalize` at `window`.
- `resolvedWorkdir()`: `.freshTemp` → `NSTemporaryDirectory` + UUID;
  `.stable(path)` → `expandingTildeInPath`; both `createDirectory`.

### `CCUsageBar/CCUsageBar/UsageView.swift` (REWRITTEN)
- `UsageStackView(viewModels:)` — VStack of per-provider `ProviderHeader` +
  `ProviderSection`, separated by Dividers, `.frame(width: 560, height: 500)`.
- `ProviderSection(viewModel:)` — the state switch
  (idle/loading/loaded/rateLimited/needsSetup/error); needsSetup uses
  `viewModel.provider.command`.
- `ProviderHeader(title:)` — small label bar.

### `CCUsageBar/CCUsageBar/StatusBarController.swift` (MODIFIED)
- `viewModels = [UsageViewModel(provider: .claude), UsageViewModel(provider: .codex)]`.
- `togglePopover` / prefetch fan out `run()` / `run(force: true)`;
  `popoverDidClose` fans out `dismissPopover()`.
- Added `refreshTimer` (300s; body wrapped in `MainActor.assumeIsolated`) and a
  prefetch of both providers at the end of `init`.
- `popover.contentSize` 560×500; accessibility label "AI Usage".

### `build.sh` (NEW)
Compiles `CCUsageBar/CCUsageBar/*.swift` via `swiftc`
(`-swift-version 5 -default-isolation MainActor -O`), builds the bundle +
`Info.plist` (`CFBundleIconFile=AppIcon`, id `com.lionhylra.CCUsageBar`,
`LSUIElement true`), builds `AppIcon.icns` from the appiconset PNGs via
`iconutil`, and ad-hoc codesigns with entitlements. `--run` kills the existing
instance and relaunches. Output → `build/` (gitignored).

### `.gitignore` (MODIFIED)
Added `build/`.

---

## 5. Errors & Fixes

- Codex `/status` keystrokes appeared ignored → it was sitting at the **"Do you
  trust the contents of this directory?"** prompt consuming input. Fixed with a
  gate + stable trusted workdir.
- The harness accidentally triggered Codex's **"Update available!"** prompt and
  selected the default "Update now" (ran an npm update). Lesson: never blindly
  send Enter — the update gate sends **Esc**.
- Swift `main actor-isolated … in a synchronous nonisolated context` errors were
  spurious; fixed type-check by adding `-default-isolation MainActor`.
- `Timer` closure warning → wrapped body in `MainActor.assumeIsolated`.
- `finalize` bug: `guard isFetching` came **after** `cancelQuery()` (which clears
  the flag) → moved the guard **before** `cancelQuery()`.
- Nested `has`/`hasRegex` touched main-actor `scanBuffer` from a nonisolated
  context → captured `buf`/`cbuf` locals first.
- **Codex timeout (the big one):** stuck at `waitingForBanner`. Diagnosis via
  `log stream` revealed (a) `stripANSI` didn't strip OSC, flooding the buffer
  with `0;codex-workdir` title spam; (b) char-by-char rendering meant
  "OpenAI Codex" never appeared contiguously. **Final fix:** timed flow
  (bootDelay → send `/status` → captureWindow + SIGWINCH → finalize), abandoning
  string detection for Codex.
- `log stream --predicate` form failed (`(eval):log: too many arguments`) via the
  shell wrapper → used `--process CCUsageBar`.
- `os.Logger` info/debug not found by `log show` (memory-only) → used live
  `log stream`.

---

## 6. Known Limitations

- **Codex timings are fixed** (3.5s boot, 4s capture). Generous for the
  background prefetch, but a slow machine under load could occasionally catch a
  partial box — the next refresh corrects it.
- **First-run Codex trust on a fresh machine:** auto-answering the trust prompt is
  unreliable for Codex's char-positioned rendering. Anyone forking may need to run
  `codex` once in `~/Library/Application Support/CCUsageBar/codex-workdir` to grant
  trust. (The dev machine was already trusted during testing.)

---

## 7. Build & Debug Cheatsheet

```bash
./build.sh              # build into ./build/CCUsageBar.app
./build.sh --run        # build, kill running instance, relaunch

# Watch the running app's logs live (info/debug are memory-only):
log stream --process CCUsageBar --level debug

# Type-check a single file the way Xcode would:
swiftc -typecheck -swift-version 5 -default-isolation MainActor \
  -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 <file>.swift
```

Xcode.app is **not installed** (Command Line Tools only) — `xcodebuild` and
opening the `.xcodeproj` do not work; use `./build.sh`.

---

## 8. Status

All three reported issues fixed and verified: stacked Claude+Codex, app icon,
caching/background refresh, and the Codex-not-working bug. Both providers finalize
cleanly (Claude shows `Current session █████ 42% used`; Codex shows the
`╭─ OpenAI Codex … 5h limit / Weekly limit / Credits` box), no timeouts, no stray
PTY processes.

**Uncommitted** at time of writing — 6 files changed (`Provider.swift` + `build.sh`
new; `UsageViewModel.swift` / `UsageView.swift` / `StatusBarController.swift` /
`.gitignore` modified; `build/` gitignored).
