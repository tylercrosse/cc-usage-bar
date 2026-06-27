import SwiftUI
import AppKit

private let headerColor = Color(nsColor: .separatorColor).opacity(0.12)
private let progressTrackColor = Color(nsColor: .quaternaryLabelColor)
private let statusDotColor = Color(nsColor: .tertiaryLabelColor)
private let linkColor = Color(nsColor: .linkColor)

/// Accent for a metric: a base color (text + bottom of the bar) plus a slightly
/// lighter shade for the top of the progress-bar gradient.
private struct MetricAccent {
    let base: Color
    let light: Color

    init(_ hex: UInt) {
        base = Color(hex: hex)
        light = Color(hex: hex, lightenedBy: 0.18)
    }
}

/// "Violet + Warn" palette — tweak the hex values here to retune the bars.
/// Violet up to 60% used, amber through 80%, coral above 80%.
private enum UsagePalette {
    static let low      = MetricAccent(0x8B7FE8)   // violet       (≤60% used)
    static let mid      = MetricAccent(0xE3A24A)   // amber        (60–80% used)
    static let high     = MetricAccent(0xE8675C)   // coral        (>80% used)
    static let quantity = MetricAccent(0xA99BFF)   // light violet (credits / counts)
}

private extension Color {
    /// Build a color from a `0xRRGGBB` literal, optionally mixed toward white.
    init(hex: UInt, lightenedBy amount: Double = 0) {
        let r = Double((hex >> 16) & 0xFF)
        let g = Double((hex >> 8) & 0xFF)
        let b = Double(hex & 0xFF)
        func mix(_ channel: Double) -> Double { (channel + (255 - channel) * amount) / 255 }
        self.init(.sRGB, red: mix(r), green: mix(g), blue: mix(b), opacity: 1)
    }
}

/// The popover content: one labeled section per provider, stacked vertically.
struct UsageStackView: View {
    let viewModels: [UsageViewModel]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModels.enumerated()), id: \.offset) { index, viewModel in
                if index > 0 {
                    Divider()
                }
                ProviderHeader(
                    title: viewModel.provider.displayName,
                    usageURL: viewModel.provider.usageURL
                )
                ProviderSection(viewModel: viewModel)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 520, height: 440)
        .background(.regularMaterial)
    }
}

/// Thin bar naming the provider above its output section.
private struct ProviderHeader: View {
    let title: String
    let usageURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if let usageURL {
                Link(destination: usageURL) {
                    Label("Usage", systemImage: "arrow.up.right.square")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(linkColor)
                .help("Open \(title) usage")
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
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
                Color.clear

            case .loading:
                ZStack {
                    Color.clear
                    ProgressView("Loading usage\u{2026}")
                        .progressViewStyle(.circular)
                        .controlSize(.regular)
                        .foregroundStyle(.primary)
                }

            case .loaded(let snapshot):
                if snapshot.hasStructuredMetrics {
                    UsageMetricsView(snapshot: snapshot, isRefreshing: viewModel.isFetching)
                } else {
                    TerminalTextView(attributedText: snapshot.rawOutput)
                }

            case .rateLimited:
                ZStack {
                    Color.clear
                    VStack(spacing: 12) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text("Rate Limited")
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundStyle(.primary)
                        Text("Usage data is temporarily unavailable.\nPlease wait a moment and try again.")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }

            case .needsSetup:
                ZStack {
                    Color.clear
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.yellow)
                        Text("Setup Required")
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundStyle(.primary)
                        Text("Please run `\(viewModel.provider.command)` in your terminal\nto log in and complete setup first.")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }

            case .error(let message):
                ZStack(alignment: .topLeading) {
                    Color.clear
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
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(metric.valueText)
                    .font(.system(.headline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(accent.base)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let progress = metric.progress {
                MetricBarView(progress: progress, accent: accent)
            }

            if let detail = metric.detail {
                Text(detail)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct MetricBarView: View {
    let progress: Double
    let accent: MetricAccent

    private let cornerRadius: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(progressTrackColor)
                if progress > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.light, accent.base],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: proxy.size.width * progress)
                }
            }
        }
        .frame(height: 14)
    }
}

private func metricAccent(_ metric: UsageMetric) -> MetricAccent {
    guard let percent = metric.percent else {
        return UsagePalette.quantity
    }

    switch metric.direction {
    case .used:
        if percent >= 80 { return UsagePalette.high }
        if percent >= 60 { return UsagePalette.mid }
        return UsagePalette.low
    case .quantity:
        return UsagePalette.quantity
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
                Text("Refreshing")
            } else {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6, height: 6)
                Text(fetchAgeText(capturedAt))
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
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
