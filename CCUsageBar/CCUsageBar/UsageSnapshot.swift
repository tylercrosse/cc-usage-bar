import Foundation

enum UsageDirection {
    case used
    case quantity
}

struct UsageMetric: Identifiable {
    let id: String
    let title: String
    let percent: Int?
    let direction: UsageDirection
    let valueText: String
    let detail: String?
    let resetIdentifier: String?

    init(
        id: String,
        title: String,
        percent: Int?,
        direction: UsageDirection,
        valueText: String,
        detail: String?,
        resetIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.percent = percent
        self.direction = direction
        self.valueText = valueText
        self.detail = detail
        self.resetIdentifier = resetIdentifier
    }

    var progress: Double? {
        percent.map { min(max(Double($0) / 100.0, 0), 1) }
    }
}

struct UsageSnapshot {
    let providerID: String
    let metrics: [UsageMetric]
    let rawOutput: NSAttributedString
    let capturedAt: Date

    var hasStructuredMetrics: Bool {
        !metrics.isEmpty
    }
}

enum UsageSnapshotParser {
    private enum ResetRelativeStyle {
        case time
        case days
    }

    static func parse(
        provider: Provider,
        rawOutput: NSAttributedString,
        capturedAt: Date = Date()
    ) -> UsageSnapshot {
        let lines = normalizedLines(from: rawOutput.string)
        let metrics: [UsageMetric]
        switch provider.id {
        case "claude":
            metrics = parseClaude(lines: lines, providerID: provider.id, capturedAt: capturedAt)
        case "codex":
            metrics = parseCodex(lines: lines, providerID: provider.id, capturedAt: capturedAt)
        default:
            metrics = []
        }
        return UsageSnapshot(
            providerID: provider.id,
            metrics: metrics,
            rawOutput: rawOutput,
            capturedAt: capturedAt
        )
    }

    private static func parseClaude(lines: [String], providerID: String, capturedAt: Date) -> [UsageMetric] {
        var metrics: [UsageMetric] = []

        for (index, line) in lines.enumerated() {
            guard isClaudeSectionHeader(line) else { continue }

            var percent: Int?
            var detail: String?
            var resetIdentifier: String?
            let relativeStyle: ResetRelativeStyle = line.hasPrefix("Current week") ? .days : .time
            let lookaheadEnd = min(lines.count, index + 8)

            for candidate in lines[index..<lookaheadEnd] {
                if candidate != line, isClaudeSectionHeader(candidate) { break }
                if candidate.localizedCaseInsensitiveContains("what's contributing") { break }

                if percent == nil,
                   let match = captures(#"(\d{1,3})\s*%\s*used\b"#, in: candidate),
                   let parsed = Int(match[1]) {
                    percent = min(max(parsed, 0), 100)
                }
                if detail == nil, candidate.localizedCaseInsensitiveContains("resets") {
                    if let info = resetInfo(
                        in: candidate,
                        relativeStyle: relativeStyle,
                        capturedAt: capturedAt
                    ) {
                        detail = info.display
                        resetIdentifier = info.identifier
                    } else {
                        detail = candidate
                    }
                }
            }

            guard let percent else { continue }
            metrics.append(UsageMetric(
                id: "\(providerID)-\(normalizedID(line))",
                title: line,
                percent: percent,
                direction: .used,
                valueText: "\(percent)% used",
                detail: detail,
                resetIdentifier: resetIdentifier
            ))
        }

        return metrics
    }

    private static func parseCodex(lines: [String], providerID: String, capturedAt: Date) -> [UsageMetric] {
        var metrics: [UsageMetric] = []

        for (index, line) in lines.enumerated() {
            if let match = captures(#"^(.+?):\s*(?:\[[^\]]+\]\s*)?(\d{1,3})\s*%\s*(left|used)\b(.*)$"#, in: line),
               let parsed = Int(match[2]) {
                let title = cleanupTitle(match[1])
                let relativeStyle: ResetRelativeStyle = title.localizedCaseInsensitiveContains("week") ? .days : .time
                let suffix = match[3].lowercased()
                let rawPercent = min(max(parsed, 0), 100)
                let usedPercent = suffix == "left" ? 100 - rawPercent : rawPercent
                let resetInfo = codexResetInfo(
                    lines: lines,
                    metricIndex: index,
                    sameLineRemainder: match[4],
                    relativeStyle: relativeStyle,
                    capturedAt: capturedAt
                )
                metrics.append(UsageMetric(
                    id: "\(providerID)-\(normalizedID(title))",
                    title: title,
                    percent: usedPercent,
                    direction: .used,
                    valueText: "\(usedPercent)% used",
                    detail: resetInfo?.display,
                    resetIdentifier: resetInfo?.identifier
                ))
            } else if let match = captures(#"^Credits:\s*(.+)$"#, in: line) {
                let value = match[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                metrics.append(UsageMetric(
                    id: "\(providerID)-credits",
                    title: "Credits",
                    percent: nil,
                    direction: .quantity,
                    valueText: value,
                    detail: nil
                ))
            }
        }

        return metrics
    }

    private struct ResetInfo {
        let display: String
        let identifier: String
    }

    private static func codexResetInfo(
        lines: [String],
        metricIndex: Int,
        sameLineRemainder: String,
        relativeStyle: ResetRelativeStyle,
        capturedAt: Date
    ) -> ResetInfo? {
        if let info = resetInfo(
            in: sameLineRemainder,
            relativeStyle: relativeStyle,
            capturedAt: capturedAt
        ) {
            return info
        }

        let lookaheadEnd = min(lines.count, metricIndex + 5)
        guard metricIndex + 1 < lookaheadEnd else { return nil }

        for candidate in lines[(metricIndex + 1)..<lookaheadEnd] {
            if isCodexMetricLine(candidate) || candidate.hasPrefix("Credits:") {
                break
            }
            if let info = resetInfo(
                in: candidate,
                relativeStyle: relativeStyle,
                capturedAt: capturedAt
            ) {
                return info
            }
        }

        return nil
    }

    private static func resetInfo(
        in line: String,
        relativeStyle: ResetRelativeStyle,
        capturedAt: Date = Date()
    ) -> ResetInfo? {
        guard let match = captures(#"\b(resets?|renews?|refreshes?)\b[:\s-]*(.+)$"#, in: line) else {
            return nil
        }
        let verb = match[1].lowercased() == "reset" ? "Resets" : capitalizedFirst(match[1])
        let timezone = timezoneAnnotation(in: match[2]) ?? TimeZone.current.identifier
        let value = normalizedResetValue(match[2])
        guard !value.isEmpty else { return nil }
        let identifier = "\(value) (\(timezone))"

        switch relativeStyle {
        case .days:
            if let relativeDays = relativeDaysText(
                for: value,
                timezoneIdentifier: timezone,
                capturedAt: capturedAt
            ) {
                return ResetInfo(
                    display: "\(verb) in \(relativeDays) on \(value) (\(timezone))",
                    identifier: identifier
                )
            }
        case .time:
            if let relativeTime = relativeTimeText(
                for: value,
                timezoneIdentifier: timezone,
                capturedAt: capturedAt
            ) {
                return ResetInfo(
                    display: "\(verb) in \(relativeTime) at \(value) (\(timezone))",
                    identifier: identifier
                )
            }
        }

        return ResetInfo(display: "\(verb) \(value) (\(timezone))", identifier: identifier)
    }

    private static func normalizedLines(from text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingOccurrences(
                        of: "[╭╮╰╯│┃┌┐└┘├┤┬┴┼─━═║╔╗╚╝]+",
                        with: " ",
                        options: .regularExpression
                    )
                    .replacingOccurrences(of: "\u{FFFD}", with: " ")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private static func isClaudeSectionHeader(_ line: String) -> Bool {
        line == "Current session" || line.hasPrefix("Current week")
    }

    private static func cleanupTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"^[>\s_]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCodexMetricLine(_ line: String) -> Bool {
        captures(#"^.+?:\s*(?:\[[^\]]+\]\s*)?\d{1,3}\s*%\s*(?:left|used)\b"#, in: line) != nil
    }

    private static func capitalizedFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst().lowercased()
    }

    private static func normalizedResetValue(_ value: String) -> String {
        var cleaned = value
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " :—-"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasSuffix(")") && !cleaned.contains("(") {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let match = captures(#"^(\d{1,2}):(\d{2})\s+on\s+(\d{1,2})\s+([A-Za-z]{3,9})$"#, in: cleaned),
           let time = normalizedTwentyFourHourTime(hour: match[1], minute: match[2]) {
            let day = Int(match[3]).map(String.init) ?? match[3]
            return "\(normalizedMonth(match[4])) \(day) at \(time)"
        }

        if let match = captures(#"^([A-Za-z]{3,9})\s+(\d{1,2})\s+at\s+(.+)$"#, in: cleaned) {
            let time = normalizedClockTime(match[3]) ?? match[3]
            let day = Int(match[2]).map(String.init) ?? match[2]
            return "\(normalizedMonth(match[1])) \(day) at \(time)"
        }

        if let time = normalizedClockTime(cleaned) {
            return time
        }

        return cleaned
    }

    private static func timezoneAnnotation(in value: String) -> String? {
        guard let match = captures(#"\(([^)]+)\)\s*$"#, in: value) else {
            return nil
        }

        let timezone = match[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !timezone.isEmpty else { return nil }
        return timezone
    }

    private static func relativeDaysText(
        for normalizedValue: String,
        timezoneIdentifier: String,
        capturedAt: Date
    ) -> String? {
        guard let resetDate = resetDate(
            from: normalizedValue,
            timezoneIdentifier: timezoneIdentifier,
            capturedAt: capturedAt
        ) else {
            return nil
        }

        let interval = resetDate.timeIntervalSince(capturedAt)
        guard interval > 0 else { return "<1 day" }

        let days = Int(interval / 86_400)
        if days < 1 {
            return "<1 day"
        }
        return days == 1 ? "1 day" : "\(days) days"
    }

    private static func relativeTimeText(
        for normalizedValue: String,
        timezoneIdentifier: String,
        capturedAt: Date
    ) -> String? {
        guard let resetDate = resetDate(
            from: normalizedValue,
            timezoneIdentifier: timezoneIdentifier,
            capturedAt: capturedAt
        ) else {
            return nil
        }

        let interval = resetDate.timeIntervalSince(capturedAt)
        guard interval > 0 else { return "<1m" }

        let totalMinutes = max(Int(interval / 60), 0)
        guard totalMinutes >= 1 else { return "<1m" }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }

    private static func resetDate(
        from normalizedValue: String,
        timezoneIdentifier: String,
        capturedAt: Date
    ) -> Date? {
        let timezone = TimeZone(identifier: timezoneIdentifier) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        let capturedComponents = calendar.dateComponents([.year, .month, .day], from: capturedAt)
        guard let capturedYear = capturedComponents.year else { return nil }

        if let match = captures(#"^([A-Za-z]{3,9})\s+(\d{1,2})\s+at\s+(\d{1,2}):(\d{2})(am|pm)$"#, in: normalizedValue),
           let month = monthNumber(match[1]),
           let day = Int(match[2]),
           let hour = Int(match[3]),
           let minute = Int(match[4]) {
            let hour24 = hour24(hour: hour, suffix: match[5])

            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = timezone
            components.year = capturedYear
            components.month = month
            components.day = day
            components.hour = hour24
            components.minute = minute

            guard var date = calendar.date(from: components) else { return nil }
            if date < capturedAt {
                components.year = capturedYear + 1
                guard let nextYearDate = calendar.date(from: components) else { return nil }
                date = nextYearDate
            }
            return date
        }

        if let match = captures(#"^(\d{1,2}):(\d{2})(am|pm)$"#, in: normalizedValue),
           let hour = Int(match[1]),
           let minute = Int(match[2]),
           let month = capturedComponents.month,
           let day = capturedComponents.day {
            let hour24 = hour24(hour: hour, suffix: match[3])

            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = timezone
            components.year = capturedYear
            components.month = month
            components.day = day
            components.hour = hour24
            components.minute = minute

            guard var date = calendar.date(from: components) else { return nil }
            if date < capturedAt,
               let nextDay = calendar.date(byAdding: .day, value: 1, to: date) {
                date = nextDay
            }
            return date
        }

        return nil
    }

    private static func hour24(hour: Int, suffix: String) -> Int {
        if suffix.lowercased() == "am" {
            return hour == 12 ? 0 : hour
        }
        return hour == 12 ? 12 : hour + 12
    }

    private static func normalizedClockTime(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if let match = captures(#"^(\d{1,2}):(\d{2})$"#, in: trimmed) {
            return normalizedTwentyFourHourTime(hour: match[1], minute: match[2])
        }

        if let match = captures(#"^(\d{1,2})(?::(\d{2}))?\s*([ap]m)$"#, in: trimmed),
           let hour = Int(match[1]) {
            let minute = match.count > 2 && !match[2].isEmpty ? match[2] : "00"
            return "\(hour):\(minute)\(match[3].lowercased())"
        }

        return nil
    }

    private static func normalizedTwentyFourHourTime(hour: String, minute: String) -> String? {
        guard let hour = Int(hour) else { return nil }
        let clampedHour = min(max(hour, 0), 23)
        let displayHour = clampedHour % 12 == 0 ? 12 : clampedHour % 12
        let suffix = clampedHour < 12 ? "am" : "pm"
        return "\(displayHour):\(minute)\(suffix)"
    }

    private static func normalizedMonth(_ value: String) -> String {
        let key = value.lowercased()
        let months = [
            "jan": "Jan", "january": "Jan",
            "feb": "Feb", "february": "Feb",
            "mar": "Mar", "march": "Mar",
            "apr": "Apr", "april": "Apr",
            "may": "May",
            "jun": "Jun", "june": "Jun",
            "jul": "Jul", "july": "Jul",
            "aug": "Aug", "august": "Aug",
            "sep": "Sep", "sept": "Sep", "september": "Sep",
            "oct": "Oct", "october": "Oct",
            "nov": "Nov", "november": "Nov",
            "dec": "Dec", "december": "Dec",
        ]
        return months[key] ?? capitalizedFirst(value)
    }

    private static func monthNumber(_ value: String) -> Int? {
        let key = value.lowercased()
        let months = [
            "jan": 1, "january": 1,
            "feb": 2, "february": 2,
            "mar": 3, "march": 3,
            "apr": 4, "april": 4,
            "may": 5,
            "jun": 6, "june": 6,
            "jul": 7, "july": 7,
            "aug": 8, "august": 8,
            "sep": 9, "sept": 9, "september": 9,
            "oct": 10, "october": 10,
            "nov": 11, "november": 11,
            "dec": 12, "december": 12,
        ]
        return months[key]
    }

    private static func normalizedID(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }

        return (0..<match.numberOfRanges).map { index in
            let nsRange = match.range(at: index)
            guard nsRange.location != NSNotFound,
                  let range = Range(nsRange, in: text) else {
                return ""
            }
            return String(text[range])
        }
    }
}
