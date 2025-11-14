#if DEBUG
import SwiftUI

enum UITestScenario: String {
    case commentsReport = "comments_report"

    static func current(processInfo: ProcessInfo = .processInfo) -> UITestScenario? {
        if let idx = processInfo.arguments.firstIndex(of: "-UITestScenario"),
           processInfo.arguments.indices.contains(idx + 1),
           let scenario = UITestScenario(rawValue: processInfo.arguments[idx + 1]) {
            return scenario
        }
        if let env = processInfo.environment["UITEST_SCENARIO"],
           let scenario = UITestScenario(rawValue: env) {
            return scenario
        }
        return nil
    }
}

struct UITestHarnessView: View {
    let scenario: UITestScenario

    var body: some View {
        switch scenario {
        case .commentsReport:
            CommentsReportHarness()
        }
    }
}

private struct CommentsReportHarness: View {
    @StateObject private var viewModel: CommentsSheetViewModel

    init() {
        let service = CommentsUITestService()
        let moderation = CommentsUITestModeration()
        _viewModel = StateObject(wrappedValue: CommentsSheetViewModel(itemId: "uitest-comments",
                                                                       scope: .spot,
                                                                       service: service,
                                                                       moderation: moderation,
                                                                       analytics: nil))
    }

    var body: some View {
        CommentsSheet(viewModel: viewModel)
    }
}

private final class CommentsUITestService: CommentsServing {
    private let items: [CommentViewModel]

    init() {
        let base = Date()
        var seeded: [CommentViewModel] = []
        seeded.append(CommentViewModel(id: "uitest-report-target",
                                       userId: "user-report",
                                       displayName: "Jordan",
                                       avatarURL: nil,
                                       text: "Long press to report this comment.",
                                       createdAt: base,
                                       isOwn: false))
        for idx in 1..<24 {
            let comment = CommentViewModel(id: "uitest-comment-\(idx)",
                                           userId: "user-\(idx)",
                                           displayName: "Rider \(idx)",
                                           avatarURL: nil,
                                           text: "UITest filler comment \(idx)",
                                           createdAt: base.addingTimeInterval(TimeInterval(-idx * 180)),
                                           isOwn: idx == 6)
            seeded.append(comment)
        }
        items = seeded
    }

    func fetchFirstPage(itemId: String, scope: CommentScope, limit: Int) async throws -> (items: [CommentViewModel], next: String?) {
        let slice = Array(items.prefix(limit))
        let next = items.count > limit ? String(limit) : nil
        return (slice, next)
    }

    func fetchNextPage(itemId: String, scope: CommentScope, token: String, limit: Int) async throws -> (items: [CommentViewModel], next: String?) {
        guard let start = Int(token) else { return ([], nil) }
        let end = min(start + limit, items.count)
        guard start < end else { return ([], nil) }
        let slice = Array(items[start..<end])
        let next = end < items.count ? String(end) : nil
        return (slice, next)
    }

    func post(itemId: String, scope: CommentScope, text: String, idempotencyKey: String) async throws -> CommentViewModel {
        CommentViewModel(id: "posted-\(UUID().uuidString)",
                         userId: "me",
                         displayName: "You",
                         avatarURL: nil,
                         text: text,
                         createdAt: Date(),
                         isOwn: true)
    }

    func delete(commentId: String, itemId: String, scope: CommentScope) async throws {}
}

private final class CommentsUITestModeration: ModerationReporting {
    func report(commentId: String, itemId: String, scope: CommentScope, reason: ReportReason, message: String?) async throws {
        try await Task.sleep(nanoseconds: 120_000_000)
        UserDefaults.standard.set(commentId, forKey: "UITestLastReportedComment")
    }
}
#endif
