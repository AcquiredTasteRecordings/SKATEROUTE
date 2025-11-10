/// Core/AppRouter.swift
import SwiftUI

/// Central, app-wide navigation coordinator for SwiftUI.
///
/// This object is intentionally lightweight and self-contained so it
/// does not depend on feature modules. It exposes a small set of routes
/// and basic push/pop/present helpers that screens can call via
/// `@EnvironmentObject var router: AppRouter`.
///
/// Conformance to `Equatable` and `Hashable` is identity-based so it can
/// be stored inside sets/dictionaries and compared without leaking any
/// navigation state into equality.
final class AppRouter: ObservableObject, Equatable, Hashable {
    // MARK: - Public navigation state

    /// Stack-based navigation used by `NavigationStack`.
    @Published var path: NavigationPath = .init()

    /// Optional modal presentations the app may show.
    @Published var presentedSheet: Sheet?
    @Published var presentedFullScreen: FullScreenCover?

    // MARK: - Routes

    /// The primary set of destinations in the app. Keep these generic and
    /// free of feature types so the router stays stable.
    enum Route: Hashable {
        case home
        case map
        case settings
        case profile(userId: String)
        case spot(id: String)
        case routeDetail(id: String)
    }

    /// Sheets that can be presented modally.
    enum Sheet: Hashable, Identifiable {
        case share(text: String)
        case reportIssue
        case paywall

        var id: String { String(describing: self) }
    }

    /// Full-screen cover presentations.
    enum FullScreenCover: Hashable, Identifiable {
        case camera
        case onboarding

        var id: String { String(describing: self) }
    }

    // MARK: - Init

    init(path: NavigationPath = .init()) {
        self.path = path
    }

    // MARK: - Navigation helpers

    func push(_ route: Route) {
        path.append(route)
    }

    func push(_ routes: [Route]) {
        routes.forEach { path.append($0) }
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func pop(toRoot: Bool) {
        if toRoot { path.removeLast(path.count) } else { pop() }
    }

    func reset(_ routes: [Route] = []) {
        path = NavigationPath()
        push(routes)
    }

    // MARK: - Modal helpers

    func present(sheet: Sheet) { presentedSheet = sheet }
    func dismissSheet() { presentedSheet = nil }

    func present(fullScreen cover: FullScreenCover) { presentedFullScreen = cover }
    func dismissFullScreen() { presentedFullScreen = nil }

    // MARK: - Deep Link handling (basic)

    /// Attempts to handle an incoming URL and convert it into a navigation action.
    /// Extend this as your universal links/deeplinks grow.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let host = url.host else { return false }
        let components = url.pathComponents.filter { $0 != "/" }

        switch (host.lowercased(), components.first, components.dropFirst()) {
        case ("spot", let id?, _):
            push(.spot(id: id))
            return true
        case ("user", let id?, _):
            push(.profile(userId: id))
            return true
        case ("route", let id?, _):
            push(.routeDetail(id: id))
            return true
        case ("map", _, _):
            push(.map)
            return true
        case ("settings", _, _):
            push(.settings)
            return true
        case ("home", _, _):
            push(.home)
            return true
        default:
            return false
        }
    }

    // MARK: - Equatable & Hashable (identity-based)

    static func == (lhs: AppRouter, rhs: AppRouter) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

// MARK: - Convenience EnvironmentKey

private struct AppRouterKey: EnvironmentKey {
    typealias Value = <#type#>
    
    static let defaultValue: AppRouter = AppRouter()
}

extension EnvironmentValues {
    var appRouter: AppRouter {
        get { self[AppRouterKey.self] }
        set { self[AppRouterKey.self] = newValue }
    }
}

// MARK: - Preview Support

#if DEBUG
struct AppRouter_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack(path: .constant(NavigationPath())) {
            Text("Router Preview")
                .environmentObject(AppRouter())
        }
    }
}
#endif
