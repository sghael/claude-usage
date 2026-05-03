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

    init(appState: AppState) {
        self.appState = appState
        // Read keychain once at startup and cache
        if let creds = KeychainService.loadClaudeCodeToken() {
            cachedToken = creds.accessToken
        }
        requestNotificationPermission()
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
        let sessionThreshold = Double(appState.sessionThreshold)
        let weeklyThreshold = Double(appState.weeklyThreshold)

        // Session alert
        let sessionPct = usage.session.percentage
        if usage.session.utilization >= sessionThreshold && lastNotifiedSessionPct < Int(sessionThreshold) {
            lastNotifiedSessionPct = sessionPct
            sendNotification(
                title: "Claude Session: \(sessionPct)% used",
                body: "Session usage is above \(appState.sessionThreshold)%. \(usage.session.resetDescription)."
            )
        }
        if usage.session.utilization < sessionThreshold { lastNotifiedSessionPct = -1 }

        // Weekly alert (delayed so both are visible)
        let weeklyPct = usage.weeklyAll.percentage
        if usage.weeklyAll.utilization >= weeklyThreshold && lastNotifiedWeeklyPct < Int(weeklyThreshold) {
            lastNotifiedWeeklyPct = weeklyPct
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.sendNotification(
                    title: "Claude Weekly: \(weeklyPct)% used",
                    body: "Weekly usage is above \(self.appState.weeklyThreshold)%. \(usage.weeklyAll.resetDescription)."
                )
            }
        }
        if usage.weeklyAll.utilization < weeklyThreshold { lastNotifiedWeeklyPct = -1 }
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
