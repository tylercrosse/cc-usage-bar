import Foundation
import UserNotifications

final class UsageThresholdNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UsageThresholdNotifier()

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let thresholds = [60, 80, 100]
    private let statePrefix = "UsageThresholdNotifier"
    private var authorizationRequestStarted = false

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        guard !authorizationRequestStarted else { return }
        authorizationRequestStarted = true

        let center = center
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func evaluate(snapshot: UsageSnapshot, provider: Provider) {
        for metric in snapshot.metrics where metric.direction == .used {
            evaluate(metric: metric, snapshot: snapshot, provider: provider)
        }
    }

    private func evaluate(metric: UsageMetric, snapshot: UsageSnapshot, provider: Provider) {
        guard let percent = metric.percent else { return }

        let windowIdentifier = metric.resetIdentifier ?? fallbackWindowIdentifier(for: snapshot.capturedAt)
        let baseKey = "\(statePrefix).\(provider.id).\(metric.id)"
        let windowKey = "\(baseKey).window"
        let lastPercentKey = "\(baseKey).lastPercent"
        let notifiedThresholdsKey = "\(baseKey).notifiedThresholds"

        let storedWindow = defaults.string(forKey: windowKey)
        let hasPreviousPercent = defaults.object(forKey: lastPercentKey) != nil
        guard storedWindow == windowIdentifier, hasPreviousPercent else {
            defaults.set(windowIdentifier, forKey: windowKey)
            defaults.set(percent, forKey: lastPercentKey)
            defaults.removeObject(forKey: notifiedThresholdsKey)
            return
        }

        let previousPercent = defaults.integer(forKey: lastPercentKey)
        var notifiedThresholds = storedThresholds(forKey: notifiedThresholdsKey)
        let crossedThresholds = thresholds.filter { threshold in
            previousPercent < threshold && percent >= threshold && !notifiedThresholds.contains(threshold)
        }

        if !crossedThresholds.isEmpty {
            notifiedThresholds.formUnion(crossedThresholds)
            defaults.set(notifiedThresholds.sorted(), forKey: notifiedThresholdsKey)
            crossedThresholds.forEach { threshold in
                postNotification(provider: provider, metric: metric, threshold: threshold, percent: percent)
            }
        }

        defaults.set(percent, forKey: lastPercentKey)
    }

    private func postNotification(provider: Provider, metric: UsageMetric, threshold: Int, percent: Int) {
        let title = "\(provider.displayName) \(limitName(for: metric)) usage reached \(threshold)%"
        let body = "Current usage is \(percent)% used for \(metric.title)."
        let identifier = "usage-threshold-\(provider.id)-\(metric.id)-\(threshold)-\(UUID().uuidString)"
        let center = center

        center.getNotificationSettings { settings in
            func addNotification() {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default

                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                center.add(request) { _ in }
            }

            switch settings.authorizationStatus {
            case .authorized, .provisional:
                addNotification()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    addNotification()
                }
            default:
                break
            }
        }
    }

    private func limitName(for metric: UsageMetric) -> String {
        let title = metric.title.lowercased()
        if title.contains("week") {
            return "weekly"
        }
        if title.contains("session") {
            return "session"
        }
        if title.contains("5h") {
            return "5h"
        }
        return metric.title
    }

    private func storedThresholds(forKey key: String) -> Set<Int> {
        Set((defaults.array(forKey: key) ?? []).compactMap { value in
            if let int = value as? Int {
                return int
            }
            if let number = value as? NSNumber {
                return number.intValue
            }
            return nil
        })
    }

    private func fallbackWindowIdentifier(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "captured-%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
