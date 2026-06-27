import SwiftUI
import AppKit

private let bgColor = Color(nsColor: NSColor(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0, alpha: 1))
private let headerColor = Color(nsColor: NSColor(red: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2E / 255.0, alpha: 1))

/// The popover content: one labeled section per provider, stacked vertically.
struct UsageStackView: View {
    let viewModels: [UsageViewModel]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModels.enumerated()), id: \.offset) { index, viewModel in
                if index > 0 {
                    Divider().overlay(Color.black.opacity(0.6))
                }
                ProviderHeader(title: viewModel.provider.displayName)
                ProviderSection(viewModel: viewModel)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 520, height: 380)
        .background(bgColor)
    }
}

/// Thin bar naming the provider above its output section.
private struct ProviderHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(headerColor)
    }
}

/// Renders a single provider's current state (loading / loaded / error / …).
struct ProviderSection: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                bgColor

            case .loading:
                ZStack {
                    bgColor
                    ProgressView("Loading usage\u{2026}")
                        .progressViewStyle(.circular)
                        .controlSize(.regular)
                        .foregroundStyle(.white)
                        .colorScheme(.dark)
                }

            case .loaded(let snapshot):
                if snapshot.hasStructuredMetrics {
                    UsageMetricsView(snapshot: snapshot, isRefreshing: viewModel.isFetching)
                } else {
                    TerminalTextView(attributedText: snapshot.rawOutput)
                }

            case .rateLimited:
                ZStack {
                    bgColor
                    VStack(spacing: 12) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text("Rate Limited")
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundStyle(.white)
                        Text("Usage data is temporarily unavailable.\nPlease wait a moment and try again.")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }

            case .needsSetup:
                ZStack {
                    bgColor
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.yellow)
                        Text("Setup Required")
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundStyle(.white)
                        Text("Please run `\(viewModel.provider.command)` in your terminal\nto log in and complete setup first.")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }

            case .error(let message):
                ZStack(alignment: .topLeading) {
                    bgColor
                    ScrollView {
                        Text("Error: \(message)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UsageMetricsView: View {
    let snapshot: UsageSnapshot
    let isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(snapshot.metrics) { metric in
                MetricRowView(metric: metric)
            }
            Spacer(minLength: 0)
            FetchStatusView(capturedAt: snapshot.capturedAt, isRefreshing: isRefreshing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(bgColor)
    }
}

private struct MetricRowView: View {
    let metric: UsageMetric

    var body: some View {
        let accent = metricAccent(metric)

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(metric.title)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(metric.valueText)
                    .font(.system(.headline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let progress = metric.progress {
                MetricBarView(progress: progress, color: accent)
            }

            if let detail = metric.detail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }
}

private struct MetricBarView: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.13))
                if progress > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * progress)
                }
            }
        }
        .frame(height: 7)
    }
}

private func metricAccent(_ metric: UsageMetric) -> Color {
    guard let percent = metric.percent else {
        return Color(nsColor: NSColor.systemCyan)
    }

    switch metric.direction {
    case .used:
        if percent >= 80 { return Color(nsColor: NSColor.systemRed) }
        if percent >= 60 { return Color(nsColor: NSColor.systemOrange) }
        return Color(nsColor: NSColor.systemGreen)
    case .quantity:
        return Color(nsColor: NSColor.systemCyan)
    }
}

private struct FetchStatusView: View {
    let capturedAt: Date
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 7) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.58)
                    .frame(width: 10, height: 10)
                    .colorScheme(.dark)
                Text("Refreshing")
            } else {
                Circle()
                    .fill(.white.opacity(0.32))
                    .frame(width: 6, height: 6)
                Text(fetchAgeText(capturedAt))
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white.opacity(0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private func fetchAgeText(_ capturedAt: Date) -> String {
    let age = max(Date().timeIntervalSince(capturedAt), 0)
    if age < 10 {
        return "Fetched just now"
    }

    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return "Fetched \(formatter.localizedString(for: capturedAt, relativeTo: Date()))"
}
