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
    static func parse(
        provider: Provider,
        rawOutput: NSAttributedString,
        capturedAt: Date = Date()
    ) -> UsageSnapshot {
        let lines = normalizedLines(from: rawOutput.string)
        let metrics: [UsageMetric]
        switch provider.id {
        case "claude":
            metrics = parseClaude(lines: lines, providerID: provider.id)
        case "codex":
            metrics = parseCodex(lines: lines, providerID: provider.id)
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

    private static func parseClaude(lines: [String], providerID: String) -> [UsageMetric] {
        var metrics: [UsageMetric] = []

        for (index, line) in lines.enumerated() {
            guard isClaudeSectionHeader(line) else { continue }

            var percent: Int?
            var detail: String?
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
                    detail = candidate
                }
            }

            guard let percent else { continue }
            metrics.append(UsageMetric(
                id: "\(providerID)-\(normalizedID(line))",
                title: line,
                percent: percent,
                direction: .used,
                valueText: "\(percent)% used",
                detail: detail
            ))
        }

        return metrics
    }

    private static func parseCodex(lines: [String], providerID: String) -> [UsageMetric] {
        var metrics: [UsageMetric] = []

        for (index, line) in lines.enumerated() {
            if let match = captures(#"^(.+?):\s*(?:\[[^\]]+\]\s*)?(\d{1,3})\s*%\s*(left|used)\b(.*)$"#, in: line),
               let parsed = Int(match[2]) {
                let title = cleanupTitle(match[1])
                let suffix = match[3].lowercased()
                let rawPercent = min(max(parsed, 0), 100)
                let usedPercent = suffix == "left" ? 100 - rawPercent : rawPercent
                metrics.append(UsageMetric(
                    id: "\(providerID)-\(normalizedID(title))",
                    title: title,
                    percent: usedPercent,
                    direction: .used,
                    valueText: "\(usedPercent)% used",
                    detail: codexResetDetail(lines: lines, metricIndex: index, sameLineRemainder: match[4])
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

    private static func codexResetDetail(
        lines: [String],
        metricIndex: Int,
        sameLineRemainder: String
    ) -> String? {
        if let detail = resetDetail(in: sameLineRemainder) {
            return detail
        }

        let lookaheadEnd = min(lines.count, metricIndex + 5)
        guard metricIndex + 1 < lookaheadEnd else { return nil }

        for candidate in lines[(metricIndex + 1)..<lookaheadEnd] {
            if isCodexMetricLine(candidate) || candidate.hasPrefix("Credits:") {
                break
            }
            if let detail = resetDetail(in: candidate) {
                return detail
            }
        }

        return nil
    }

    private static func resetDetail(in line: String) -> String? {
        guard let match = captures(#"\b(resets?|renews?|refreshes?)\b[:\s-]*(.+)$"#, in: line) else {
            return nil
        }
        let verb = match[1].lowercased() == "reset" ? "Resets" : capitalizedFirst(match[1])
        let value = cleanupResetValue(match[2])
        guard !value.isEmpty else { return nil }
        return "\(verb) \(value)"
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

    private static func cleanupResetValue(_ value: String) -> String {
        var cleaned = value
            .trimmingCharacters(in: CharacterSet(charactersIn: " :—-"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasSuffix(")") && !cleaned.contains("(") {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned
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

        return (0..<match.numberOfRanges).compactMap { index in
            let nsRange = match.range(at: index)
            guard nsRange.location != NSNotFound,
                  let range = Range(nsRange, in: text) else {
                return nil
            }
            return String(text[range])
        }
    }
}
