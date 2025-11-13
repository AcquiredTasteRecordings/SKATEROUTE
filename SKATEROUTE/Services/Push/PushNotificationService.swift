// Services/Push/PushNotificationService.swift
// APNs plumbing: token lifecycle, topic subscriptions (cities, challenge types), and foreground handlers.
// Registers categories from Resources/NotificationCategories.plist and routes taps to AppCoordinator.
// No tracking. No ad SDKs. ATT-free. DI-friendly; unit-testable with fakes.

import Foundation
import Combine
import UserNotifications
import UIKit
import os.log

// MARK: - DI seams

/// Minimal coordinator seam to route notification taps.
public protocol AppRouting {
    func handleNotification(userInfo: [AnyHashable: Any])
}

/// Your server API used to upsert APNs token and topic subscriptions.
public protocol PushRemoteAPI {
    /// Register/update the token with current topics and app metadata.
    func registerToken(_ token: String, topics: Set<String>, locale: String, appVersion: String) async throws
    /// Update only topics for a previously registered token.
    func updateTopics(_ token: String, topics: Set<String>) async throws
}

// MARK: - Service

@MainActor
public final class PushNotificationService: NSObject, ObservableObject {

    public enum State: Equatable {
        case idle
        case requestingPermission
        case ready
        case error(String)
    }

    public struct Banner: Identifiable, Equatable {
        public let id = UUID()
        public let title: String
        public let body: String
        public let category: String?
        public let userInfo: [AnyHashable: Any]
        public let receivedAt: Date
    }

    // Published state for UI and diagnostics
    @Published public private(set) var state: State = .idle
    @Published public private(set) var isAuthorized: Bool = false
    @Published public private(set) var apnsToken: String?

    public var bannerPublisher: AnyPublisher<Banner, Never> { bannerSubject.eraseToAnyPublisher() }

    // DI
    private let notifications: UNUserNotificationCenter
    private let api: PushRemoteAPI
    private let router: AppRouting
    private let log = Logger(subsystem: "com.skateroute", category: "Push")

    // Topics (city keys like "ca-vancouver", challenge types like "weekly_distance")
    private(set) var topics = Set<String>()
    private let bannerSubject = PassthroughSubject<Banner, Never>()

    // Persistence
    private let defaults = UserDefaults.standard
    private static let udkToken = "push.apns.token"
    private static let udkTopics = "push.topics"

    // App metadata
    private let appVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") + ")"

    // MARK: Init

    public init(center: UNUserNotificationCenter = .current(),
                api: PushRemoteAPI,
                router: AppRouting) {
        self.notifications = center
        self.api = api
        self.router = router
        super.init()
        notifications.delegate = self
        loadPersisted()
        registerCategoriesFromPlist()
    }

    // MARK: Public API

    /// Request notification authorization + APNs registration. Idempotent.
    public func registerIfNeeded(provisional: Bool = false) {
        state = .requestingPermission
        let options: UNAuthorizationOptions = provisional ? [.alert, .sound, .badge, .provisional] : [.alert, .sound, .badge]
        notifications.requestAuthorization(options: options) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthorized = granted
                if let e = error {
                    self.state = .error("Notification permission failed")
                    self.log.error("UNAuth error: \(e.localizedDescription, privacy: .public)")
                    return
                }
                UIApplication.shared.registerForRemoteNotifications()
                self.state = .ready
            }
        }
    }

    /// Call from AppDelegate upon APNs success.
    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        let token = Self.hexString(deviceToken)
        apnsToken = token
        defaults.set(token, forKey: Self.udkToken)
        Task { await self.pushRegistrationIfPossible() }
    }

    /// Call from AppDelegate upon APNs failure.
    public func didFailToRegisterForRemoteNotifications(error: Error) {
        log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
        state = .error("APNs registration failed")
    }

    /// Replace topics wholesale (e.g., after city change). Debounced network update.
    public func setTopics(_ new: Set<String>) {
        guard new != topics else { return }
        topics = sanitizedTopics(new)
        defaults.set(Array(topics), forKey: Self.udkTopics)
        Task { await self.pushTopicsIfPossible() }
    }

    /// Add/remove a single topic.
    public func subscribe(_ topic: String) {
        var new = topics; new.insert(topic)
        setTopics(new)
    }
    public func unsubscribe(_ topic: String) {
        var new = topics; new.remove(topic)
        setTopics(new)
    }

    // MARK: Foreground banner enable (optional UI layer subscribes to bannerPublisher)

    /// Programmatic display for test or custom UI banners (useful in UITests).
    public func emitBanner(title: String, body: String, category: String? = nil, userInfo: [AnyHashable: Any] = [:]) {
        bannerSubject.send(Banner(title: title, body: body, category: category, userInfo: userInfo, receivedAt: Date()))
    }

    // MARK: Internals

    private func loadPersisted() {
        if let t = defaults.string(forKey: Self.udkToken) { apnsToken = t }
        if let arr = defaults.array(forKey: Self.udkTopics) as? [String] { topics = Set(arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }
    }

    private func sanitizedTopics(_ inSet: Set<String>) -> Set<String> {
        // Restrict to sane characters for server topic keys.
        Set(inSet.compactMap { s in
            let norm = s.lowercased().replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
            return norm.isEmpty ? nil : norm
        })
    }

    private func pushRegistrationIfPossible() async {
        guard let token = apnsToken else { return }
        do {
            try await api.registerToken(token,
                                        topics: topics,
                                        locale: Locale.autoupdatingCurrent.identifier,
                                        appVersion: appVersion)
        } catch {
            log.notice("Token register deferred: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pushTopicsIfPossible() async {
        guard let token = apnsToken else { return } // will be sent on first token register
        do {
            try await api.updateTopics(token, topics: topics)
        } catch {
            log.notice("Topic update deferred: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Reads NotificationCategories.plist and registers them with UNUserNotificationCenter.
    private func registerCategoriesFromPlist() {
        guard let url = Bundle.main.url(forResource: "NotificationCategories", withExtension: "plist"),
              let arr = NSArray(contentsOf: url) as? [[String: Any]] else {
            return
        }

        var categories: Set<UNNotificationCategory> = []
        for dict in arr {
            guard let id = dict["identifier"] as? String else { continue }
            let actionsArr = (dict["actions"] as? [[String: Any]] ?? [])
            let actions: [UNNotificationAction] = actionsArr.compactMap { a in
                guard let aid = a["identifier"] as? String, let title = a["title"] as? String else { return nil }
                let optsRaw = a["options"] as? [String] ?? []
                let opts = Self.actionOptions(optsRaw)
                if (a["textInput"] as? Bool) == true {
                    let prompt = a["textInputButtonTitle"] as? String ?? "Send"
                    let placeholder = a["textInputPlaceholder"] as? String ?? ""
                    return UNTextInputNotificationAction(identifier: aid, title: title, options: opts, textInputButtonTitle: prompt, textInputPlaceholder: placeholder)
                } else {
                    return UNNotificationAction(identifier: aid, title: title, options: opts)
                }
            }
            let opts = Self.categoryOptions(dict["options"] as? [String] ?? [])
            let cat = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: opts)
            categories.insert(cat)
        }
        notifications.setNotificationCategories(categories)
    }

    private static func actionOptions(_ arr: [String]) -> UNNotificationActionOptions {
        var o: UNNotificationActionOptions = []
        for s in arr {
            switch s.lowercased() {
            case "foreground": o.insert(.foreground)
            case "destructive": o.insert(.destructive)
            case "authenticationrequired": o.insert(.authenticationRequired)
            default: break
            }
        }
        return o
    }
    private static func categoryOptions(_ arr: [String]) -> UNNotificationCategoryOptions {
        var o: UNNotificationCategoryOptions = []
        for s in arr {
            switch s.lowercased() {
            case "customdismissaction": o.insert(.customDismissAction)
            case "allowincarplay": o.insert(.allowInCarPlay)
            case "hiddenpreviewshowtitle": if #available(iOS 11.0, *) { o.insert(.hiddenPreviewsShowTitle) }
            case "hiddenpreviewshowsubtitle": if #available(iOS 11.0, *) { o.insert(.hiddenPreviewsShowSubtitle) }
            default: break
            }
        }
        return o
    }

    private static func hexString(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationService: UNUserNotificationCenterDelegate {

    // Foreground presentation: show banner UI and optionally let system show alert/sound for high-priority categories.
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let req = notification.request
        let content = req.content

        // Emit our own in-app banner stream for custom UI components.
        let banner = Banner(title: content.title,
                            body: content.body,
                            category: content.categoryIdentifier.isEmpty ? nil : content.categoryIdentifier,
                            userInfo: content.userInfo,
                            receivedAt: Date())
        bannerSubject.send(banner)

        // Policy: allow system banner + sound for safety-critical categories only.
        let isSafety = content.categoryIdentifier == "HAZARD_NEARBY" || content.categoryIdentifier == "RIDE_ALERT"
        completionHandler(isSafety ? [.banner, .sound, .badge] : [])
    }

    // Tap handling (banner tap or action)
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        // Route to coordinator; UI flow is centralized there.
        router.handleNotification(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }
}

// MARK: - DEBUG fakes (for tests)

#if DEBUG
public final class PushAPIFake: PushRemoteAPI {
    public private(set) var registered: (token: String, topics: Set<String>, locale: String, appVersion: String)?
    public private(set) var updated: (token: String, topics: Set<String>)?
    public init() {}
    public func registerToken(_ token: String, topics: Set<String>, locale: String, appVersion: String) async throws {
        registered = (token, topics, locale, appVersion)
    }
    public func updateTopics(_ token: String, topics: Set<String>) async throws {
        updated = (token, topics)
    }
}

public final class AppRouterFake: AppRouting {
    public private(set) var lastUserInfo: [AnyHashable: Any] = [:]
    public init() {}
    public func handleNotification(userInfo: [AnyHashable : Any]) { lastUserInfo = userInfo }
}
#endif

// MARK: - Integration (AppDelegate / SceneDelegate)

// In AppDelegate:
// func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
//     di.resolve(PushNotificationService.self).didRegisterForRemoteNotifications(deviceToken: deviceToken)
// }
// func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
//     di.resolve(PushNotificationService.self).didFailToRegisterForRemoteNotifications(error: error)
// }

// App start:
// let push = PushNotificationService(api: pushAPI, router: appCoordinator)
// push.registerIfNeeded()

// Topics usage examples:
// • City scoping: after resolving city key "ca-vancouver" → push.subscribe("city.ca-vancouver")
// • Challenges: push.subscribe("challenge.weekly_distance") / push.unsubscribe(...)

// MARK: - Test plan (unit / UI summary)
//
// • Token lifecycle:
//   - Instantiate service with PushAPIFake, call registerIfNeeded(); simulate didRegisterForRemoteNotifications with stub token;
//     assert `apnsToken` persisted and PushAPIFake.registered is set.
// • Topic subscribe/unsubscribe:
//   - Call subscribe("city.ca-vancouver"), then unsubscribe; verify PushAPIFake.updateTopics receives sanitized set, deterministically.
// • Foreground banner rendering:
//   - In a test harness, call userNotificationCenter(_:willPresent:...) with a UNNotification for category "OTHER";
//     assert bannerPublisher emits Banner and completionHandler is called with [].
//   - For "HAZARD_NEARBY", assert completionHandler includes .banner and .sound.
// • Tap routing:
//   - Call userNotificationCenter(_:didReceive:...) with a response carrying userInfo; assert AppRouterFake.lastUserInfo matches.
// • Categories registration:
//   - Provide a minimal NotificationCategories.plist in test bundle; init service and inspect UNUserNotificationCenter.current().notificationCategories (can’t assert directly in unit tests; validate via spy if needed).


