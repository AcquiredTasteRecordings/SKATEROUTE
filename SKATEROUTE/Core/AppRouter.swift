import Foundation
import SwiftUI

public enum AppRoute: Hashable, Codable, Sendable {
    case home
    case map
    case feed
    case challenges
    case leaderboard
    case comments
    case settings
    case spotDetail(id: UUID)
}

@MainActor
public final class AppRouter: ObservableObject, Sendable {
    @Published public var path: [AppRoute] = []
    public init(path: [AppRoute] = []) { self.path = path }
    public func push(_ route: AppRoute) { path.append(route) }
    public func pop() { _ = path.popLast() }
    public func reset(to route: AppRoute? = nil) {
        path.removeAll()
        if let r = route { path = [r] }
    }
}
