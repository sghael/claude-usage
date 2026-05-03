import Foundation
import UserNotifications

@MainActor
final class UsagePollingService {
    private let appState: AppState
    private let apiService = ClaudeAPIService()
    private var timer: Timer?
    private var lastNotifiedSessionPct: Int = -1
    private var lastNotifiedWeeklyPct: Int = -1
    private var cachedToken: String?
    private var lastKnownIntervalMinutes: Int

    init(appState: AppState) {
        self.appState = appState
        self.lastKnownIntervalMinutes = appState.refreshIntervalMinutes
        // Read keychain once at startup and cache
        if let creds = KeychainService.loadClaudeCodeToken() {
            cachedToken = creds.accessToken
        }
        requestNotificationPermission()
        observeRefreshIntervalChanges()
    }

    /// Reschedule the polling timer when the user changes the interval in Settings.
    /// `@AppStorage` writes flow through `UserDefaults.didChangeNotification`.
    private func observeRefreshIntervalChanges() {
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                guard let self else { return }
                let current = self.appState.refreshIntervalMinutes
                guard current != self.lastKnownIntervalMinutes else { continue }
                self.lastKnownIntervalMinutes = current
                self.rescheduleTimer()
            }
        }
    }

    func start() {
        refreshNow()
        rescheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refreshNow() {
        Task { await refresh() }
    }

    func rescheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(appState.refreshIntervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    private func refresh() async {
        guard let token = cachedToken else {
            appState.isConfigured = false
            appState.error = "Not connected — run `claude auth login` in your terminal, then relaunch."
            return
        }

        appState.isConfigured = true
        appState.isLoading = true
        appState.error = nil

        do {
            let usage = try await apiService.pingForUsage(accessToken: token)
            appState.usage = usage
            checkAlerts(usage)
        } catch ClaudeAPIError.authenticationFailed {
            // Token expired — try re-reading from keychain once
            if let creds = KeychainService.loadClaudeCodeToken() {
                cachedToken = creds.accessToken
                do {
                    let usage = try await apiService.pingForUsage(accessToken: creds.accessToken)
                    appState.usage = usage
                    checkAlerts(usage)
                } catch {
                    appState.error = friendlyError(error)
                }
            } else {
                cachedToken = nil
                appState.isConfigured = false
                appState.error = "Session expired — run `claude auth login` in your terminal, then relaunch."
            }
        } catch {
            // Keep showing last known data on transient errors
            if appState.usage.lastUpdated != .distantPast {
                appState.error = "Refresh failed — showing last known data. \(friendlyError(error))"
            } else {
                appState.error = friendlyError(error)
            }
        }

        appState.isLoading = false
    }

    private func friendlyError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return "No internet connection."
            case .timedOut: return "Request timed out. Will retry."
            case .cannotConnectToHost, .networkConnectionLost: return "Can't reach Anthropic API. Will retry."
            default: return "Network issue. Will retry."
            }
        }
        if let apiError = error as? ClaudeAPIError {
            return apiError.localizedDescription
        }
        return "Something went wrong. Will retry."
    }

    private func checkAlerts(_ usage: ClaudeUsageData) {
        evaluateAlert(
            label: "Session",
            limit: usage.session,
            thresholdPercent: appState.sessionThreshold,
            lastNotifiedKeyPath: \.lastNotifiedSessionPct,
            deliveryDelay: 0
        )
        // Weekly is delayed so both notifications are visible if they fire on the same poll.
        evaluateAlert(
            label: "Weekly",
            limit: usage.weeklyAll,
            thresholdPercent: appState.weeklyThreshold,
            lastNotifiedKeyPath: \.lastNotifiedWeeklyPct,
            deliveryDelay: 2
        )
    }

    /// Fires a notification once when `limit.utilization` first crosses `thresholdPercent`,
    /// and rearms when it dips back below. `lastNotifiedKeyPath` carries the per-alert
    /// dedupe state so session and weekly alerts don't share a counter.
    private func evaluateAlert(
        label: String,
        limit: UsageLimit,
        thresholdPercent: Int,
        lastNotifiedKeyPath: ReferenceWritableKeyPath<UsagePollingService, Int>,
        deliveryDelay: TimeInterval
    ) {
        let threshold = Double(thresholdPercent)
        let pct = limit.percentage

        if limit.utilization >= threshold && self[keyPath: lastNotifiedKeyPath] < thresholdPercent {
            self[keyPath: lastNotifiedKeyPath] = pct
            let title = "Claude \(label): \(pct)% used"
            let body = "\(label) usage is above \(thresholdPercent)%. \(limit.resetDescription)."
            if deliveryDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + deliveryDelay) {
                    self.sendNotification(title: title, body: body)
                }
            } else {
                sendNotification(title: title, body: body)
            }
        }
        if limit.utilization < threshold {
            self[keyPath: lastNotifiedKeyPath] = -1
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if !granted {
                print("[ClaudeUsage] Notification permission not granted, will use alerts instead")
            }
        }
    }

    private func sendNotification(title: String, body: String) {
        // Try UNUserNotificationCenter first; fall back to osascript only on failure.
        // The fallback exists because unsigned local builds can't deliver UN notifications.
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "usage-alert-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                self?.sendOSANotification(title: title, body: body)
            }
        }
    }

    private func sendOSANotification(title: String, body: String) {
        let script = "display notification \"\(escapeForAppleScript(body))\" with title \"\(escapeForAppleScript(title))\" sound name \"Glass\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
