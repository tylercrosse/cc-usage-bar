import AppKit
import Foundation

/// A pre-composer prompt to auto-dismiss during launch (e.g. a trust or update
/// prompt) and the bytes to send when its `trigger` substring is seen.
struct LaunchGate {
    let trigger: String
    let send: String
}

/// Where the CLI session runs.
enum Workdir {
    /// A fresh empty temp directory each launch (so the CLI has no project context).
    case freshTemp
    /// A persistent directory (path may start with `~`). Used so Codex's one-time
    /// folder-trust grant persists and the prompt only appears on the first run ever.
    case stable(String)
}

/// How to extract the displayable region from the parsed terminal frame.
enum TrimStrategy {
    /// From the line containing `marker` through the end (Claude's `/usage`).
    case fromMarker(String)
    /// The box-drawn (╭ … ╰) region whose body contains `marker` (Codex's `/status`).
    case boxContaining(String)
}

/// Everything provider-specific about driving a CLI's usage command over a PTY.
/// The PTY plumbing, ANSI parsing, timers, and session lifecycle in
/// `UsageViewModel` are otherwise provider-agnostic.
struct Provider {
    /// Stable identifier, e.g. "claude" / "codex".
    let id: String
    /// Short label shown as the section header in the popover.
    let displayName: String
    /// Executable run via `zsh -l -c <command>` (resolved on the login-shell PATH).
    let command: String
    /// Slash command that prints usage, e.g. "/usage" / "/status".
    let usageCommand: String
    /// PTY size. Codex needs more rows so its `/status` box renders fully in the
    /// live frame instead of scrolling into history.
    let ptyRows: UInt16
    let ptyCols: UInt16
    /// Regex marking the REPL/composer is ready to accept the usage command.
    let bannerPattern: String
    /// Prompts to clear before the banner (trust, update, theme picker, …).
    let gates: [LaunchGate]
    /// Substring to await as the command's echo before pressing Enter. When nil,
    /// the command is submitted after `submitDelay` instead (Codex renders the
    /// typed command char-by-char, so there is no findable echo substring).
    let commandEcho: String?
    /// Delay before pressing Enter when `commandEcho` is nil.
    let submitDelay: TimeInterval
    /// Substring marking the usage output has begun. Ignored when `captureWindow`
    /// is set (timed flow).
    let resultTrigger: String
    /// Time-based launch: instead of matching a banner string, submit the usage
    /// command this long after launch. Codex renders char-by-char and scrolls its
    /// banner away, so string detection is unreliable; nil = use `bannerPattern`.
    let bootDelay: TimeInterval?
    /// Time-based capture: instead of matching `resultTrigger` then idling, capture
    /// for this fixed window after submitting (with a SIGWINCH redraw halfway), then
    /// finalize. nil = use `resultTrigger` + idle detection.
    let captureWindow: TimeInterval?
    /// Substring indicating a rate-limit error, or nil if the CLI has none.
    let rateLimitTrigger: String?
    /// Substrings indicating the CLI needs login/setup first.
    let setupTriggers: [String]
    /// Force a full redraw via a PTY resize so diff-rendering TUIs (Ink, ratatui)
    /// emit every cell rather than skipping unchanged ones.
    let needsSigwinchRedraw: Bool
    /// How to trim the parsed frame down to the displayable region.
    let trim: TrimStrategy
    /// Where the session runs.
    let workdir: Workdir
    /// Whether the CLI session is kept alive and reused between queries. Codex is
    /// relaunched each time (cheap, and avoids re-driving its composer).
    let reusesSession: Bool
}

extension Provider {
    static let claude = Provider(
        id: "claude",
        displayName: "Claude",
        command: "claude",
        usageCommand: "/usage",
        ptyRows: 24, ptyCols: 68,
        bannerPattern: "Claude Code v\\d+",
        gates: [LaunchGate(trigger: "Quick safety check", send: "\r")],
        commandEcho: "/usage",
        submitDelay: 0,
        resultTrigger: "Current session",
        bootDelay: nil,
        captureWindow: nil,
        rateLimitTrigger: "rate_limit_error",
        setupTriggers: [
            "Welcome to Claude Code",
            "Choose the text style that looks best with your terminal",
            "Claude Code can be used with your Claude subscription",
        ],
        needsSigwinchRedraw: true,
        trim: .fromMarker("Current session"),
        workdir: .freshTemp,
        reusesSession: true
    )

    static let codex = Provider(
        id: "codex",
        displayName: "Codex",
        command: "codex",
        usageCommand: "/status",
        // Tall enough that the whole /status box renders in the live frame.
        ptyRows: 42, ptyCols: 68,
        bannerPattern: "OpenAI Codex",
        gates: [
            // Untrusted-directory prompt: "Yes, continue" is the default.
            LaunchGate(trigger: "trust the contents of this directory", send: "\r"),
            // Update prompt's default is "Update now" — Esc dismisses it instead.
            LaunchGate(trigger: "Update available", send: "\u{1B}"),
        ],
        commandEcho: nil,
        submitDelay: 0.6,
        // Unused for Codex (timed flow), kept for completeness.
        resultTrigger: "5h limit:",
        // Codex's TUI renders char-by-char and scrolls its banner away, so we drive
        // it on timers instead of string matching: wait ~3.5s for boot, then send
        // /status and capture for ~4s (SIGWINCH redraw halfway).
        bootDelay: 3.5,
        captureWindow: 4.0,
        rateLimitTrigger: nil,
        setupTriggers: ["Sign in with ChatGPT", "Not logged in", "codex login"],
        needsSigwinchRedraw: true,
        trim: .boxContaining("5h limit:"),
        workdir: .stable("~/Library/Application Support/CCUsageBar/codex-workdir"),
        reusesSession: false
    )
}

extension TrimStrategy {
    /// Reduce a fully parsed frame to just the region worth showing.
    func apply(to attributed: NSAttributedString) -> NSAttributedString {
        let plain = attributed.string
        switch self {
        case .fromMarker(let marker):
            guard let range = plain.range(of: marker) else { return attributed }
            let lineStart = plain[..<range.lowerBound].lastIndex(of: "\n")
                .map { plain.index(after: $0) } ?? plain.startIndex
            return attributed.attributedSubstring(
                from: NSRange(lineStart..<plain.endIndex, in: plain))

        case .boxContaining(let marker):
            guard let range = plain.range(of: marker) else { return attributed }
            // Walk up to the nearest box-top border and down to the box-bottom
            // border so the extracted region is a complete ╭ … ╰ box.
            let lines = plain.split(separator: "\n", omittingEmptySubsequences: false)
            var markerLine = 0
            var offset = plain.startIndex
            for (i, line) in lines.enumerated() {
                let end = plain.index(offset, offsetBy: line.count)
                if range.lowerBound >= offset && range.lowerBound <= end { markerLine = i; break }
                offset = plain.index(after: end) // skip the "\n"
            }
            var top = markerLine
            while top > 0 && !lines[top].contains("╭") { top -= 1 }
            var bottom = markerLine
            while bottom < lines.count - 1 && !lines[bottom].contains("╰") { bottom += 1 }
            // Rebuild the NSRange spanning [top-line-start ... bottom-line-end].
            func lineStartIndex(_ n: Int) -> String.Index {
                var idx = plain.startIndex
                for _ in 0..<n {
                    guard let nl = plain[idx...].firstIndex(of: "\n") else { return plain.endIndex }
                    idx = plain.index(after: nl)
                }
                return idx
            }
            let startIdx = lineStartIndex(top)
            let endIdx = lineStartIndex(bottom + 1) // start of line after the bottom border
            guard startIdx < endIdx else { return attributed }
            return attributed.attributedSubstring(from: NSRange(startIdx..<endIdx, in: plain))
        }
    }
}
