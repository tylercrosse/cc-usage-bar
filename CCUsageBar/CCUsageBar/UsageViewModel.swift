import AppKit
import Combine
import Darwin
import OSLog

private let log = Logger(subsystem: "com.ccusagebar", category: "UsageViewModel")

// fork() is marked unavailable in Swift for thread-safety reasons, but we need it for PTY.
// Access it via dlsym to bypass the Swift-level unavailability annotation.
private let _fork: @convention(c) () -> pid_t = {
    let handle = dlopen(nil, RTLD_LAZY)
    let sym = dlsym(handle, "fork")
    return unsafeBitCast(sym, to: (@convention(c) () -> pid_t).self)
}()

// WIFEXITED and WEXITSTATUS are C macros not available in Swift — implement manually.
// From sys/wait.h: _WSTATUS(x) = (x & 0x7f), WIFEXITED = (_WSTATUS(x) == 0),
// WEXITSTATUS = ((x >> 8) & 0xff)
@inline(__always) private func swiftWIFEXITED(_ status: Int32) -> Bool {
    return (status & 0x7f) == 0
}
@inline(__always) private func swiftWEXITSTATUS(_ status: Int32) -> Int32 {
    return (status >> 8) & 0xff
}

/// Write a string to a PTY file descriptor.
@discardableResult
private func ptySend(_ text: String, to fd: Int32) -> Int {
    text.withCString { ptr in write(fd, ptr, strlen(ptr)) }
}

/// Decode PTY output bytes as UTF-8 without reinterpreting a split glyph as Latin-1.
private func decode(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

enum UsageState {
    case idle
    case loading
    case loaded(UsageSnapshot)
    case rateLimited
    case needsSetup
    case error(String)
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var state: UsageState = .idle
    @Published private(set) var isFetching = false

    let provider: Provider

    init(provider: Provider) {
        self.provider = provider
    }

    private enum Stage {
        case idle               // session alive, no active query — discard incoming data
        case waitingForBanner   // waiting for the CLI's banner / composer-ready signal
        case waitingForPrompt   // sent the usage command, waiting for echo before sending \r
        case waitingForResult   // sent \r, waiting for the result trigger
        case capturing          // collecting final output
    }

    private var childPid: pid_t = 0
    private var masterFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timeoutWork: DispatchWorkItem?
    private var idleWork: DispatchWorkItem?
    private var stage: Stage = .idle
    private var scanBuffer = ""
    private var accumulatedData = Data()
    // Launch gates already handled this query, so a re-seen trigger doesn't re-fire.
    private var handledGates = Set<String>()

    private func resetScan() {
        scanBuffer = ""
    }

    // Incremented on every run(). Every async callback (Task, DispatchWorkItem) captures
    // the ID at creation time and bails out if it no longer matches — preventing stale
    // callbacks from a previous query from clobbering the new one.
    private var queryId = 0

    private var sessionLive: Bool { childPid > 0 && masterFd >= 0 }

    // Caching: keep the last successful result so the popover shows data instantly
    // (stale-while-revalidate) instead of a blank "Loading…" every time — Codex in
    // particular takes ~10s to relaunch and fetch.
    private var lastLoaded: UsageSnapshot?
    private var lastFetch: Date = .distantPast
    /// Don't refetch more often than this when cached data already exists.
    private let minRefreshInterval: TimeInterval = 60

    /// Show cached data immediately, then refresh in the background if it's stale.
    /// Pass `force` to always refetch (e.g. an explicit manual refresh).
    func run(force: Bool = false) {
        if let cached = lastLoaded {
            state = .loaded(cached)          // show stale data right away
        }
        if isFetching { return }             // a fetch is already in flight
        if !force, lastLoaded != nil, Date().timeIntervalSince(lastFetch) < minRefreshInterval {
            return                           // cached data is still fresh enough
        }
        startFetch()
    }

    private func startFetch() {
        cancelQuery()
        isFetching = true
        queryId += 1
        let currentQueryId = queryId
        handledGates.removeAll()
        log.info("startFetch() [\(self.provider.id)] qid=\(currentQueryId) sessionLive=\(self.sessionLive) pid=\(self.childPid) fd=\(self.masterFd)")

        // Cancel and recreate the read source for each query.
        // A DispatchSourceRead on a PTY master FD can lose its kqueue registration
        // after extended inactivity on macOS, causing it to silently stop firing even
        // when new data arrives. Recreating it guarantees a fresh kernel event filter.
        readSource?.cancel()
        readSource = nil

        accumulatedData = Data()
        resetScan()
        // Only show the spinner when there's nothing cached to display.
        if lastLoaded == nil { state = .loading }

        if sessionLive {
            // Reuse the existing session (providers that keep it alive). ESC was sent
            // on popover dismiss, so the REPL is back at its prompt — submit directly.
            log.info("run() reusing session fd=\(self.masterFd)")
            let capturedMaster = masterFd
            readSource = makeReadSource(master: capturedMaster, queryId: currentQueryId)
            readSource?.resume()
            submitUsageCommand(master: capturedMaster, queryId: currentQueryId)
            scheduleTimeout(queryId: currentQueryId)
        } else {
            // Launch a fresh session.
            log.info("run() launching fresh session")
            stage = .waitingForBanner
            launchSession(queryId: currentQueryId)
        }
    }

    /// Send the usage command, then either wait for its echo (providers that echo
    /// the typed command) or press Enter after a fixed delay (providers that render
    /// input char-by-char, so there is no findable echo substring).
    private func submitUsageCommand(master: Int32, queryId: Int) {
        resetScan()
        log.info("submit \(self.provider.usageCommand) fd=\(master)")
        ptySend(provider.usageCommand, to: master)
        if let window = provider.captureWindow {
            // Timed flow (Codex): start capturing now, press Enter shortly, then
            // redraw partway through and finalize at the end of the window.
            stage = .capturing
            accumulatedData = Data()
            DispatchQueue.main.asyncAfter(deadline: .now() + provider.submitDelay) { [weak self] in
                guard let self, self.queryId == queryId else { return }
                DispatchQueue.global(qos: .userInitiated).async { ptySend("\r", to: master) }
                self.beginTimedCapture(queryId: queryId, window: window)
            }
        } else if provider.commandEcho != nil {
            stage = .waitingForPrompt
        } else {
            stage = .waitingForResult
            DispatchQueue.main.asyncAfter(deadline: .now() + provider.submitDelay) { [weak self] in
                guard let self, self.queryId == queryId else { return }
                DispatchQueue.global(qos: .userInitiated).async { ptySend("\r", to: master) }
            }
        }
    }

    /// Codex timed capture: repaint partway through the window, finalize at its end.
    private func beginTimedCapture(queryId: Int, window: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + window * 0.4) { [weak self] in
            guard let self, self.queryId == queryId else { return }
            self.forceRedraw()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + window) { [weak self] in
            guard let self, self.queryId == queryId else { return }
            self.finalize(queryId: queryId)
        }
    }

    /// Resize the PTY (SIGWINCH) to force a diff-rendering TUI (Ink, ratatui) to
    /// repaint every cell rather than skipping unchanged ones (which read as blank
    /// in our virtual-screen parser).
    private func forceRedraw() {
        guard provider.needsSigwinchRedraw, masterFd >= 0 else { return }
        let fd = masterFd
        let rows = provider.ptyRows
        let cols = provider.ptyCols
        DispatchQueue.global(qos: .userInitiated).async {
            var ws = winsize(ws_row: rows, ws_col: cols - 1, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(fd, UInt(TIOCSWINSZ), &ws)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 536, ws_ypixel: 0)
                _ = ioctl(fd, UInt(TIOCSWINSZ), &ws)
            }
        }
    }

    // MARK: - Session launch

    /// Resolve (creating if needed) the directory the CLI session should run in.
    private func resolvedWorkdir() -> String {
        let fm = FileManager.default
        switch provider.workdir {
        case .freshTemp:
            let dir = NSTemporaryDirectory() + "cc-usage-\(provider.id)-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            return dir
        case .stable(let path):
            let expanded = (path as NSString).expandingTildeInPath
            try? fm.createDirectory(atPath: expanded, withIntermediateDirectories: true)
            return expanded
        }
    }

    private func launchSession(queryId: Int) {
        // Open PTY master
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0 else {
            state = .error("Failed to open PTY: \(String(cString: strerror(errno)))")
            return
        }
        guard let slaveNamePtr = ptsname(master) else {
            close(master)
            state = .error("Failed to get PTY slave name")
            return
        }
        let slaveName = String(cString: slaveNamePtr)
        masterFd = master

        // Set PTY window size. Width matches the popover (560px − 12px padding each
        // side ≈ 68 cols at Menlo 13pt); height is provider-specific so tall TUIs
        // (Codex) render their whole output in the live frame instead of scrolling.
        var winSize = winsize(ws_row: provider.ptyRows, ws_col: provider.ptyCols, ws_xpixel: 536, ws_ypixel: 0)
        _ = ioctl(master, UInt(TIOCSWINSZ), &winSize)

        // Resolve (and create) the working directory in the parent, before fork.
        let workdir = resolvedWorkdir()

        let pid = _fork()
        guard pid >= 0 else {
            close(master)
            masterFd = -1
            state = .error("fork() failed: \(String(cString: strerror(errno)))")
            return
        }

        if pid == 0 {
            // Child: set up PTY as controlling terminal and exec claude
            close(master)
            _ = setsid()
            let slave = slaveName.withCString { open($0, O_RDWR) }
            guard slave >= 0 else { _exit(1) }
            _ = ioctl(slave, UInt(TIOCSCTTY), 0)
            _ = dup2(slave, STDIN_FILENO)
            _ = dup2(slave, STDOUT_FILENO)
            _ = dup2(slave, STDERR_FILENO)
            if slave > STDERR_FILENO { close(slave) }
            _ = setenv("TERM", "xterm-256color", 1)
            _ = setenv("COLORTERM", "truecolor", 1)
            // Start in the provider's working directory (fresh temp for Claude so it
            // has no project context; a stable trusted dir for Codex).
            _ = workdir.withCString { chdir($0) }
            // Use a login shell so the CLI is found on the user's PATH.
            var args: [UnsafeMutablePointer<Int8>?] = [
                strdup("/bin/zsh"), strdup("-l"), strdup("-c"), strdup(provider.command), nil
            ]
            execv("/bin/zsh", &args)
            _exit(127)
        }

        // Parent: attach read source and start monitoring
        childPid = pid
        log.info("launchSession() forked pid=\(pid) fd=\(master)")
        readSource = makeReadSource(master: master, queryId: queryId)
        readSource?.resume()

        scheduleTimeout(queryId: queryId)

        // Time-based launch (Codex): submit the usage command after a fixed boot
        // delay instead of matching a banner string. Gates (trust/update) are still
        // handled by the read source during this window.
        if let boot = provider.bootDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + boot) { [weak self] in
                guard let self, self.queryId == queryId, self.stage == .waitingForBanner else { return }
                log.info("boot delay elapsed, submitting \(self.provider.usageCommand)")
                self.submitUsageCommand(master: master, queryId: queryId)
            }
        }

        // Safety net: if claude exits unexpectedly, surface the error and mark session dead.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let exitStatus = status
            Task { @MainActor [weak self] in
                log.info("waitpid returned pid=\(pid) status=\(exitStatus) WIFEXITED=\(swiftWIFEXITED(exitStatus)) code=\(swiftWEXITSTATUS(exitStatus))")
                guard let self else { return }
                // Mark session dead if we haven't already replaced it with a new one.
                if self.childPid == pid {
                    log.info("marking session dead (childPid was \(pid))")
                    self.childPid = 0
                }
                // Only surface an exit error if we were actively fetching.
                // Closing the PTY master (in teardownSession) sends SIGHUP to the CLI,
                // causing zsh to exit — expected and not an error.
                guard self.isFetching else { return }
                if swiftWIFEXITED(exitStatus) && swiftWEXITSTATUS(exitStatus) != 0 {
                    let code = swiftWEXITSTATUS(exitStatus)
                    self.isFetching = false
                    self.state = .error("\(self.provider.command) exited with code \(code). Is it installed and on your PATH?")
                    self.teardownSession()
                }
            }
        }
    }

    // MARK: - Read source

    private func makeReadSource(master: Int32, queryId: Int) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: master,
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(master, &buf, buf.count)
            if n <= 0 {
                log.warning("read() returned \(n) errno=\(errno) fd=\(master) qid=\(queryId)")
                return
            }
            let chunk = Data(buf[0..<n])
            log.debug("read \(n) bytes qid=\(queryId)")
            Task { @MainActor [weak self] in
                // Discard events from a previous query's source that fired after run()
                // incremented queryId and installed a fresh source.
                guard let self, self.queryId == queryId else {
                    log.debug("discarding stale event (currentQid=\(self?.queryId ?? -1) eventQid=\(queryId))")
                    return
                }
                // Session alive but no active query — discard without regex work.
                if case .idle = self.stage {
                    self.resetScan()
                    return
                }
                let text = decode(chunk)
                self.scanBuffer += self.stripANSI(text)
                // A trigger matches in the stripANSI buffer or its whitespace-stripped
                // form (Codex spaces characters out, so the compacted form is what
                // catches its gate prompts). Capture locals so the nested helpers
                // don't touch main-actor state from a nonisolated context.
                let buf = self.scanBuffer
                let cbuf = buf.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
                func has(_ s: String) -> Bool {
                    buf.contains(s) || cbuf.contains(s.replacingOccurrences(of: " ", with: ""))
                }
                func hasRegex(_ p: String) -> Bool {
                    buf.range(of: p, options: .regularExpression) != nil
                        || cbuf.range(of: p.replacingOccurrences(of: " ", with: ""), options: .regularExpression) != nil
                }
                log.debug("[\(self.provider.id, privacy: .public)] stage=\(String(describing: self.stage), privacy: .public)")
                switch self.stage {
                case .idle:
                    break  // handled above — unreachable
                case .waitingForBanner:
                    // The CLI needs login/setup first.
                    if self.provider.setupTriggers.contains(where: { has($0) }) {
                        log.info("→ needsSetup detected")
                        self.isFetching = false
                        self.state = .needsSetup
                        self.teardownSession()
                        return
                    }
                    // Clear any pre-composer gate (trust prompt, update prompt, …)
                    // exactly once each, then keep waiting for the banner.
                    if let gate = self.provider.gates.first(where: {
                        !self.handledGates.contains($0.trigger) && has($0.trigger)
                    }) {
                        log.info("→ gate '\(gate.trigger)' detected, responding")
                        self.handledGates.insert(gate.trigger)
                        self.resetScan()
                        let send = gate.send
                        DispatchQueue.global(qos: .userInitiated).async {
                            ptySend(send, to: master)
                        }
                    } else if self.provider.bootDelay == nil, hasRegex(self.provider.bannerPattern) {
                        log.info("→ banner detected, submitting \(self.provider.usageCommand)")
                        self.submitUsageCommand(master: master, queryId: queryId)
                    }
                case .waitingForPrompt:
                    // Wait for the REPL to echo the command back before sending \r.
                    // This avoids a fixed delay and ensures the prompt is interactive.
                    if let echo = self.provider.commandEcho, has(echo) {
                        log.info("→ command echo detected, sending \\r")
                        self.stage = .waitingForResult
                        self.resetScan()
                        DispatchQueue.global(qos: .userInitiated).async {
                            ptySend("\r", to: master)
                        }
                    }
                case .waitingForResult:
                    if let rateTrigger = self.provider.rateLimitTrigger, has(rateTrigger) {
                        log.info("→ rate limit detected")
                        self.isFetching = false
                        self.state = .rateLimited
                        self.teardownSession()
                        return
                    }
                    // String-based result detection (Claude). Timed providers (Codex)
                    // enter capturing from submitUsageCommand instead.
                    if self.provider.captureWindow == nil, has(self.provider.resultTrigger) {
                        log.info("→ result trigger '\(self.provider.resultTrigger)' detected, entering capturing")
                        self.stage = .capturing
                        self.accumulatedData = Data()
                        self.resetScan()
                        self.forceRedraw()
                        self.rescheduleIdleTimer(queryId: queryId)
                    }
                case .capturing:
                    self.accumulatedData.append(chunk)
                    // Timed providers finalize on a fixed schedule; others idle-detect.
                    if self.provider.captureWindow == nil {
                        self.rescheduleIdleTimer(queryId: queryId)
                    }
                }
                // Prevent unbounded growth while waiting for a trigger string.
                // No trigger string is longer than a few hundred characters.
                if self.scanBuffer.count > 4096 {
                    self.scanBuffer = String(self.scanBuffer.suffix(2048))
                }
            }
        }
        return source
    }

    // MARK: - Timers

    private func scheduleTimeout(queryId: Int) {
        let timeout = DispatchWorkItem { [weak self] in
            self?.handleTimeout(queryId: queryId)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        timeoutWork = timeout
    }

    private func rescheduleIdleTimer(queryId: Int) {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.finalize(queryId: queryId)
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Finalization

    private func finalize(queryId: Int) {
        // Discard stale finalize calls: either from a previous query (queryId mismatch)
        // or from a race where run() changed the stage before this Task ran.
        guard self.queryId == queryId, stage == .capturing else {
            log.info("finalize() skipped qid=\(queryId) currentQid=\(self.queryId) stage=\(String(describing: self.stage))")
            return
        }
        guard isFetching else { return }
        log.info("finalize() executing qid=\(queryId) accumulatedBytes=\(self.accumulatedData.count)")
        cancelQuery()
        let raw = decode(accumulatedData)
        // The SIGWINCH re-render includes the full TUI (input area, tabs, content);
        // trim down to the displayable usage region per the provider's strategy.
        let fullAttr = ANSIParser.parse(raw)
        let trimmed = provider.trim.apply(to: fullAttr)
        let fetchedAt = Date()
        let snapshot = UsageSnapshotParser.parse(provider: provider, rawOutput: trimmed, capturedAt: fetchedAt)
        lastLoaded = snapshot
        lastFetch = fetchedAt
        state = .loaded(snapshot)
        UsageThresholdNotifier.shared.evaluate(snapshot: snapshot, provider: provider)
        // Providers that don't keep their session alive are torn down now.
        if !provider.reusesSession {
            teardownSession()
        }
    }

    private func handleTimeout(queryId: Int) {
        guard self.queryId == queryId else {
            log.info("handleTimeout() skipped stale qid=\(queryId)")
            return
        }
        log.error("handleTimeout() fired qid=\(queryId) stage=\(String(describing: self.stage))")
        let tail = String(scanBuffer.suffix(500))
        // Set error BEFORE tearing down so finalize()'s guard exits early.
        isFetching = false
        // Keep showing stale data if we have it; otherwise surface the timeout.
        if let cached = lastLoaded {
            state = .loaded(cached)
        } else {
            state = .error("Timed out (stage: \(String(describing: stage)))\n\nLast output:\n\(tail)")
        }
        teardownSession()
    }

    // MARK: - ANSI

    private func stripANSI(_ text: String) -> String {
        // Replace ANSI sequences with a space (not empty) so cursor-movement commands
        // between words don't cause adjacent words to merge together. Order matters:
        //   1. OSC  (ESC ] … BEL/ST)  — Codex spams title updates; their payload
        //      ("0;codex-workdir", "10;?") must be removed whole, not left as text.
        //   2. CSI  (ESC [ … final)
        //   3. ESC + single char       — fallback for the rest.
        let stripped = text.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}\\[[^@-~]*[@-~]|\u{1B}[^\\[]",
            with: " ",
            options: .regularExpression
        )
        // Collapse runs of spaces/tabs to a single space so trigger strings match cleanly.
        return stripped.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }

    // MARK: - Session lifecycle

    /// Called when the popover is dismissed. Sends ESC to exit the /usage view so
    /// the REPL is back at the › prompt before the next query, then cancels timers.
    func dismissPopover() {
        if provider.reusesSession {
            if sessionLive {
                let fd = masterFd
                log.info("dismissPopover() sending ESC fd=\(fd)")
                DispatchQueue.global(qos: .userInitiated).async {
                    ptySend("\u{1B}", to: fd)
                }
            }
            cancelQuery()
        } else {
            // Non-reuse providers (Codex): tear the session down so nothing lingers.
            teardownSession()
        }
    }

    /// Cancels any in-progress query timers but keeps the claude session alive.
    func cancelQuery() {
        log.info("cancelQuery() stage=\(String(describing: self.stage))")
        timeoutWork?.cancel()
        timeoutWork = nil
        idleWork?.cancel()
        idleWork = nil
        stage = .idle
        isFetching = false
    }

    /// Full teardown: kills the claude process and closes the PTY.
    /// Called on timeout, rate-limit errors, and needs-setup conditions.
    func teardownSession() {
        log.info("teardownSession() pid=\(self.childPid) fd=\(self.masterFd)")
        isFetching = false
        cancelQuery()
        readSource?.cancel()
        readSource = nil
        if childPid > 0 { kill(childPid, SIGTERM); childPid = 0 }
        if masterFd >= 0 { close(masterFd); masterFd = -1 }
    }
}
