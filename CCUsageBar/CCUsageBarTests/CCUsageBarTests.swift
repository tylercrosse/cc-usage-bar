import Testing
import AppKit
@testable import CCUsageBar

struct ANSIParserTests {
    let font = NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    @Test func plainText() {
        let result = ANSIParser.parse("hello world", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("hello world"))
    }

    @Test func bold() {
        let result = ANSIParser.parse("\u{1B}[1mbold\u{1B}[0m", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("bold"))
        let attrs = result.attributes(at: 0, effectiveRange: nil)
        let f = attrs[.font] as? NSFont
        #expect(f?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func resetAfterBold() {
        let result = ANSIParser.parse("\u{1B}[1mbold\u{1B}[0mnormal", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("boldnormal"))
        let attrs = result.attributes(at: 4, effectiveRange: nil)
        let f = attrs[.font] as? NSFont
        #expect(f?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }

    @Test func redColor() {
        let result = ANSIParser.parse("\u{1B}[31mred\u{1B}[0m", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("red"))
        let color = result.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
        #expect(color != nil)
        #expect((color?.greenComponent ?? 1) < 0.1)
    }

    @Test func brightGreen() {
        let result = ANSIParser.parse("\u{1B}[92mbright\u{1B}[0m", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("bright"))
        let color = result.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
        #expect(color != nil)
    }

    @Test func rgbColor() {
        let result = ANSIParser.parse("\u{1B}[38;2;255;128;0morange\u{1B}[0m", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("orange"))
        let color = result.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
        #expect(abs((color?.redComponent ?? 0) - 1.0) < 0.01)
        #expect(abs((color?.greenComponent ?? 0) - 128.0 / 255.0) < 0.01)
        #expect(abs((color?.blueComponent ?? 1) - 0.0) < 0.01)
    }

    @Test func color256() {
        let result = ANSIParser.parse("\u{1B}[38;5;196mred256\u{1B}[0m", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("red256"))
        let color = result.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
        #expect(color != nil)
    }

    @Test func stripsEscapeCodes() {
        let input = "\u{1B}[1m\u{1B}[32mSuccess\u{1B}[0m: done"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("Success: done"))
    }

    @Test func multipleColorRuns() {
        let input = "\u{1B}[31mred\u{1B}[32mgreen\u{1B}[0mplain"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("redgreenplain"))
    }

    @Test func cursorForwardPreservesExistingContent() {
        let input = "hello\rhe\u{1B}[3Cd"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("hellod"))
    }

    @Test func cursorUpAndOverwrite() {
        let input = "aaa\r\nbbb\u{1B}[1AX"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        let lines = result.string.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count >= 2)
        #expect(lines[0].hasPrefix("aaaX"))
    }

    @Test func privateModesStripped() {
        let result = ANSIParser.parse("\u{1B}[?2026hhello", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("hello"))
    }

    @Test func eraseInLine() {
        let input = "hello\r\u{1B}[K"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        #expect(result.string.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test func oscSequenceStripped() {
        let result = ANSIParser.parse("before\u{1B}]0;My Title\u{07}after", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("beforeafter"))
    }

    @Test func carriageReturnOverwrites() {
        let input = "Resets 2pm\rRese\u{1B}[1Cs"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("Resets"))
    }
}

struct UsageSnapshotParserTests {
    @Test func parsesClaudeUsageRows() {
        let timezone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let capturedAt = fixedDate(year: 2026, month: 6, day: 28, hour: 10, minute: 0, timezone: timezone)
        let output = NSAttributedString(string: """
        Current session
        █████░░░░░ 47% used
        Resets 12:30pm (America/Los_Angeles)

        Current week (all models)
        ██████░░░░ 62% used
        Resets Jun 28 at 9pm (America/Los_Angeles)
        """)

        let snapshot = UsageSnapshotParser.parse(provider: .claude, rawOutput: output, capturedAt: capturedAt)

        #expect(snapshot.metrics.count == 2)
        #expect(snapshot.metrics[0].title == "Current session")
        #expect(snapshot.metrics[0].valueText == "47% used")
        #expect(snapshot.metrics[0].detail == "Resets in 2h 30m at 12:30pm (America/Los_Angeles)")
        #expect(snapshot.metrics[0].resetIdentifier == "12:30pm (America/Los_Angeles)")
        #expect(snapshot.metrics[1].title == "Current week (all models)")
        #expect(snapshot.metrics[1].valueText == "62% used")
        #expect(snapshot.metrics[1].detail == "Resets in <1 day on Jun 28 at 9:00pm (America/Los_Angeles)")
        #expect(snapshot.metrics[1].resetIdentifier == "Jun 28 at 9:00pm (America/Los_Angeles)")
    }

    @Test func parsesCodexStatusRows() {
        let timezone = TimeZone.current
        let capturedAt = fixedDate(year: 2026, month: 6, day: 27, hour: 9, minute: 0, timezone: timezone)
        let output = NSAttributedString(string: """
        ╭──────────────────────────────────────╮
        │  >_ OpenAI Codex (v0.142.3)           │
        │  5h limit:    [███░░░░] 12% left      │
        │  Resets 13:30)                        │
        │  Weekly limit:[████████░] 60% left    │
        │  Resets 16:28 on 1 Jul)               │
        │  Credits:     143 credits             │
        ╰──────────────────────────────────────╯
        """)

        let snapshot = UsageSnapshotParser.parse(provider: .codex, rawOutput: output, capturedAt: capturedAt)
        let timezoneName = timezone.identifier

        #expect(snapshot.metrics.count == 3)
        #expect(snapshot.metrics[0].title == "5h limit")
        #expect(snapshot.metrics[0].valueText == "88% used")
        #expect(snapshot.metrics[0].detail == "Resets in 4h 30m at 1:30pm (\(timezoneName))")
        #expect(snapshot.metrics[0].resetIdentifier == "1:30pm (\(timezoneName))")
        #expect(snapshot.metrics[1].title == "Weekly limit")
        #expect(snapshot.metrics[1].valueText == "40% used")
        #expect(snapshot.metrics[1].detail == "Resets in 4 days on Jul 1 at 4:28pm (\(timezoneName))")
        #expect(snapshot.metrics[1].resetIdentifier == "Jul 1 at 4:28pm (\(timezoneName))")
        #expect(snapshot.metrics[2].title == "Credits")
        #expect(snapshot.metrics[2].valueText == "143 credits")
    }

    private func fixedDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        timezone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timezone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute

        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}
