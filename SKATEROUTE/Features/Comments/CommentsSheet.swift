// Features/Comments/CommentsSheet.swift
// Lightweight comments with moderation.
// - Bottom sheet UI for item-scoped comments (video/route/spot).
// - Client-side profanity screen + gentle nudge (allow edit before post).
// - Optimistic post w/ idempotency key; offline queue-safe by service.
// - Report action wires into moderation adapter; duplicate reports collapsed.
// - A11y: Dynamic Type; ≥44pt hit targets; VO-friendly labels; high-contrast safe.
// - Privacy: no tracking; Analytics façade logs coarse actions only (no PII).

import SwiftUI
import Combine
import Foundation

// MARK: - Models (match Data models layer)

public enum CommentScope: String, Sendable { case video, route, spot }

public struct CommentViewModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let userId: String
    public let displayName: String
    public let avatarURL: URL?
    public let text: String
    public let createdAt: Date
    public let isOwn: Bool
}

// MARK: - DI seams

public protocol CommentsServing: AnyObject {
    /// Fetch first page for an item. Returns items (newest first by default) and an opaque paging token.
    func fetchFirstPage(itemId: String, scope: CommentScope, limit: Int) async throws -> (items: [CommentViewModel], next: String?)
    func fetchNextPage(itemId: String, scope: CommentScope, token: String, limit: Int) async throws -> (items: [CommentViewModel], next: String?)
    /// Post is idempotent via client-generated key; service should collapse duplicates.
    func post(itemId: String, scope: CommentScope, text: String, idempotencyKey: String) async throws -> CommentViewModel
    /// Delete only if author or moderator.
    func delete(commentId: String, itemId: String, scope: CommentScope) async throws
}

public protocol ModerationReporting: AnyObject {
    enum ReportReason: String, Sendable { case abuse, spam, offTopic, safety, other }
    /// Report a comment; backend should dedupe (userId, commentId, reason).
    func report(commentId: String, itemId: String, scope: CommentScope, reason: ReportReason, message: String?) async throws
}

// MARK: - Local profanity screen (gentle nudge, not authoritarian)

fileprivate struct ProfanityScreen {
    /// Lightweight normalized list; full list can be delivered by RemoteConfig.
    /// Keep culture-aware & minimal to avoid over-blocking.
    static let bad: [String] = ["idiot","stupid","dumb","hate"] // sample; replace via RC
    static func containsFlaggedTerms(_ text: String) -> Bool {
        let t = text.lowercased()
        return bad.contains { t.contains($0) }
    }
}

// MARK: - ViewModel

@MainActor
public final class CommentsSheetViewModel: ObservableObject {

    // Inputs
    private let itemId: String
    private let scope: CommentScope
    private let service: CommentsServing
    private let moderation: ModerationReporting
    private let analytics: AnalyticsLogging?

    // Outputs
    @Published public private(set) var items: [CommentViewModel] = []
    @Published public private(set) var nextToken: String?
    @Published public private(set) var isLoadingMore = false
    @Published public private(set) var isPosting = false
    @Published public private(set) var isReporting = false
    @Published public var draft: String = ""
    @Published public var showProfanityHint = false
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?

    // Rules
    private let maxLen = 500
    private let minLen = 1
    private let postCooldownSec: TimeInterval = 2.0 // UX: discourage spammy bursts

    private var lastPostTime: Date?
    private var cancellables = Set<AnyCancellable>()

    public init(itemId: String,
                scope: CommentScope,
                service: CommentsServing,
                moderation: ModerationReporting,
                analytics: AnalyticsLogging? = nil) {
        self.itemId = itemId
        self.scope = scope
        self.service = service
        self.moderation = moderation
        self.analytics = analytics
    }

    public func loadInitial() async {
        guard items.isEmpty else { return }
        do {
            let page = try await service.fetchFirstPage(itemId: itemId, scope: scope, limit: 30)
            items = page.items
            nextToken = page.next
        } catch {
            errorMessage = NSLocalizedString("Couldn’t load comments.", comment: "comments load fail")
        }
    }

    public func loadMoreIfNeeded(current item: CommentViewModel?) async {
        guard let item, let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard idx >= items.count - 5, !isLoadingMore, nextToken != nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await service.fetchNextPage(itemId: itemId, scope: scope, token: nextToken!, limit: 30)
            let existing = Set(items.map { $0.id })
            let filtered = next.items.filter { !existing.contains($0.id) }
            items += filtered
            nextToken = next.next
        } catch {
            // Keep existing; allow retry on further scroll.
        }
    }

    public var canPost: Bool {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isPosting && t.count >= minLen && t.count <= maxLen
    }

    public func post() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minLen, text.count <= maxLen else { return }

        // Soft nudge on profanity; allow user to post after second attempt
        if ProfanityScreen.containsFlaggedTerms(text) && !showProfanityHint {
            showProfanityHint = true
            return
        }

        // Cooldown guard
        if let last = lastPostTime, Date().timeIntervalSince(last) < postCooldownSec {
            infoMessage = NSLocalizedString("Hold up—give it a sec before posting again.", comment: "cooldown")
            return
        }

        let key = UUID().uuidString // idempotency
        isPosting = true
        analytics?.log(.init(name: "comment_post_attempt", category: .comments,
                             params: ["scope": .string(scope.rawValue)]))
        Task {
            do {
                // Optimistic insert (temporary id for UX)
                let tempId = "temp-\(key)"
                let temp = CommentViewModel(id: tempId, userId: "me", displayName: NSLocalizedString("You", comment: "you"),
                                            avatarURL: nil, text: text, createdAt: Date(), isOwn: true)
                items.insert(temp, at: 0)
                draft = ""
                showProfanityHint = false

                let saved = try await service.post(itemId: itemId, scope: scope, text: text, idempotencyKey: key)

                // Replace temp with server comment
                if let idx = items.firstIndex(where: { $0.id == tempId }) {
                    items[idx] = saved
                }
                isPosting = false
                lastPostTime = Date()
                analytics?.log(.init(name: "comment_post_success", category: .comments, params: [:]))
            } catch {
                // Rollback temp if present
                items.removeAll { $0.id.hasPrefix("temp-") }
                isPosting = false
                errorMessage = NSLocalizedString("Couldn’t post right now. Your draft is preserved.", comment: "post fail")
                draft = text
            }
        }
    }

    public func delete(_ id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let comment = items[idx]
        guard comment.isOwn else { return }
        // Optimistic remove
        items.remove(at: idx)
        Task {
            do {
                try await service.delete(commentId: id, itemId: itemId, scope: scope)
            } catch {
                // Restore on failure
                items.insert(comment, at: idx)
                errorMessage = NSLocalizedString("Couldn’t delete comment.", comment: "delete fail")
            }
        }
    }

    public func report(_ id: String, reason: ModerationReporting.ReportReason, message: String?) {
        guard !isReporting else { return }
        isReporting = true
        Task {
            do {
                try await moderation.report(commentId: id, itemId: itemId, scope: scope, reason: reason, message: message)
                infoMessage = NSLocalizedString("Thanks—report submitted for review.", comment: "report ok")
            } catch {
                errorMessage = NSLocalizedString("Report failed. Please try again later.", comment: "report fail")
            }
            isReporting = false
        }
    }
}

// MARK: - View (bottom sheet content)

public struct CommentsSheet: View {
    @ObservedObject private var vm: CommentsSheetViewModel
    @Environment(\.dismiss) private var dismiss

    @FocusState private var inputFocused: Bool

    public init(viewModel: CommentsSheetViewModel) { self.vm = viewModel }

    public var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            list
            composer
        }
        .task { await vm.loadInitial() }
        .background(.regularMaterial)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .overlay(toastOverlay)
        .accessibilityElement(children: .contain)
    }

    // MARK: - UI Sections

    private var grabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 42, height: 5)
            .padding(.top, 8)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack {
            Text(NSLocalizedString("Comments", comment: "title"))
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").imageScale(.large)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(NSLocalizedString("Close", comment: "close")))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12, pinnedViews: []) {
                ForEach(vm.items) { c in
                    CommentRow(comment: c,
                               onAppear: { Task { await vm.loadMoreIfNeeded(current: c) } },
                               onDelete: { vm.delete(c.id) },
                               onReport: { reason, msg in vm.report(c.id, reason: reason, message: msg) })
                    .padding(.horizontal, 16)
                }
            }.padding(.vertical, 10)
        }
        .accessibilityIdentifier("comments_list")
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if vm.showProfanityHint {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").imageScale(.medium)
                    Text(NSLocalizedString("Your message might be a bit spicy. Consider rephrasing, or tap Send again to post anyway.", comment: "nudge"))
                        .font(.footnote)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .transition(.opacity)
            }

            HStack(spacing: 8) {
                TextField(NSLocalizedString("Add a comment…", comment: "placeholder"),
                          text: $vm.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.sentences)
                    .disableAutocorrection(false)
                    .focused($inputFocused)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .accessibilityIdentifier("comment_textfield")

                Button(action: vm.post) {
                    if vm.isPosting { ProgressView().controlSize(.regular) }
                    else { Image(systemName: "paperplane.fill").imageScale(.large) }
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 52, minHeight: 44)
                .disabled(!vm.canPost || vm.isPosting)
                .accessibilityIdentifier("comment_send")
                .accessibilityLabel(Text(NSLocalizedString("Send", comment: "send")))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Toasts

    @ViewBuilder
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if let msg = vm.errorMessage {
                toast(text: msg, system: "exclamationmark.triangle.fill", bg: .red)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { autoDismiss { vm.errorMessage = nil } }
            } else if let info = vm.infoMessage {
                toast(text: info, system: "checkmark.seal.fill", bg: .green)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { autoDismiss { vm.infoMessage = nil } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut, value: vm.errorMessage != nil || vm.infoMessage != nil)
    }

    private func toast(text: String, system: String, bg: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: system).imageScale(.large).accessibilityHidden(true)
            Text(text).font(.callout).multilineTextAlignment(.leading)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundColor(.white)
        .accessibilityLabel(Text(text))
    }

    private func autoDismiss(_ body: @escaping () -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { body() }
        }
    }
}

// MARK: - Row cell

fileprivate struct CommentRow: View {
    let comment: CommentViewModel
    let onAppear: () -> Void
    let onDelete: () -> Void
    let onReport: (_ reason: ModerationReporting.ReportReason, _ message: String?) -> Void

    @State private var showMenu = false
    @State private var showReportSheet = false
    @State private var reportReason: ModerationReporting.ReportReason = .abuse
    @State private var reportNotes = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar(url: comment.avatarURL)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(comment.displayName).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(comment.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                Text(comment.text).font(.body).fixedSize(horizontal: false, vertical: true)
            }
        }
        .contextMenu {
            if comment.isOwn {
                Button(role: .destructive, action: onDelete) {
                    Label(NSLocalizedString("Delete", comment: "delete"), systemImage: "trash")
                }
            } else {
                Button(action: { showReportSheet = true }) {
                    Label(NSLocalizedString("Report", comment: "report"), systemImage: "flag")
                }
            }
        }
        .onAppear(perform: onAppear)
        .sheet(isPresented: $showReportSheet) { reportSheet }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(comment.displayName). \(relative(comment.createdAt)). \(comment.text)"))
    }

    private func avatar(url: URL?) -> some View {
        Group {
            if let u = url {
                AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: {
                    Color.secondary.opacity(0.15)
                }
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var reportSheet: some View {
        NavigationView {
            Form {
                Picker(NSLocalizedString("Reason", comment: "reason"), selection: $reportReason) {
                    Text(NSLocalizedString("Abuse", comment: "")).tag(ModerationReporting.ReportReason.abuse)
                    Text(NSLocalizedString("Spam", comment: "")).tag(ModerationReporting.ReportReason.spam)
                    Text(NSLocalizedString("Off-topic", comment: "")).tag(ModerationReporting.ReportReason.offTopic)
                    Text(NSLocalizedString("Safety", comment: "")).tag(ModerationReporting.ReportReason.safety)
                    Text(NSLocalizedString("Other", comment: "")).tag(ModerationReporting.ReportReason.other)
                }
                Section(header: Text(NSLocalizedString("Notes (optional)", comment: "notes"))) {
                    TextField(NSLocalizedString("Tell us what happened", comment: "notes placeholder"),
                              text: $reportNotes, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    Button(role: .destructive) {
                        onReport(reportReason, reportNotes.trimmedOrNil())
                        reportNotes = ""
                        showReportSheet = false
                    } label: {
                        Label(NSLocalizedString("Submit Report", comment: "submit"), systemImage: "flag.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .frame(minHeight: 44)
                }
            }
            .navigationTitle(Text(NSLocalizedString("Report Comment", comment: "report title")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Close", comment: "close")) { showReportSheet = false }
                }
            }
        }
    }

    private func relative(_ d: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Small helpers

fileprivate extension String {
    func trimmedOrNil() -> String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Convenience builder

public extension CommentsSheet {
    static func make(itemId: String,
                     scope: CommentScope,
                     service: CommentsServing,
                     moderation: ModerationReporting,
                     analytics: AnalyticsLogging? = nil) -> CommentsSheet {
        CommentsSheet(viewModel: .init(itemId: itemId, scope: scope, service: service, moderation: moderation, analytics: analytics))
    }
}

// MARK: - DEBUG fakes / previews

#if DEBUG
private final class CommentsFake: CommentsServing {
    private var store: [CommentViewModel] = (0..<12).map {
        CommentViewModel(id: "c\($0)", userId: $0 % 4 == 0 ? "me" : "u\($0)", displayName: $0 % 4 == 0 ? "You" : "Rider \($0)",
                         avatarURL: URL(string: "https://picsum.photos/seed/\($0)/80"), text: "Love this line! \($0)", createdAt: Date().addingTimeInterval(Double(-$0)*3600), isOwn: $0 % 4 == 0)
    }
    private var pageIdx = 0
    func fetchFirstPage(itemId: String, scope: CommentScope, limit: Int) async throws -> (items: [CommentViewModel], next: String?) {
        pageIdx = 0
        return (Array(store.prefix(10)), store.count > 10 ? "10" : nil)
    }
    func fetchNextPage(itemId: String, scope: CommentScope, token: String, limit: Int) async throws -> (items: [CommentViewModel], next: String?) {
        guard let start = Int(token) else { return ([], nil) }
        let end = min(start + 10, store.count)
        let slice = Array(store[start..<end])
        let next = end < store.count ? String(end) : nil
        return (slice, next)
    }
    func post(itemId: String, scope: CommentScope, text: String, idempotencyKey: String) async throws -> CommentViewModel {
        try await Task.sleep(nanoseconds: 200_000_000)
        let c = CommentViewModel(id: UUID().uuidString, userId: "me", displayName: "You", avatarURL: nil, text: text, createdAt: Date(), isOwn: true)
        store.insert(c, at: 0)
        return c
    }
    func delete(commentId: String, itemId: String, scope: CommentScope) async throws {
        store.removeAll { $0.id == commentId }
    }
}
private final class ModerationFake: ModerationReporting {
    func report(commentId: String, itemId: String, scope: CommentScope, reason: ReportReason, message: String?) async throws {}
}

struct CommentsSheet_Previews: PreviewProvider {
    static var previews: some View {
        CommentsSheet.make(itemId: "item123", scope: .spot, service: CommentsFake(), moderation: ModerationFake(), analytics: nil)
            .preferredColorScheme(.dark)
            .presentationDetents([.medium, .large])
            .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire to Services layer:
//    - Feed/Spots/Routes detail screens present `CommentsSheet.make(itemId:scope:...)`.
//    - `CommentsServing` should sit over your API/SwiftData cache with write-through + offline queue.
//    - `ModerationReporting` should route to SpotModerationService/Hazard moderation backends as appropriate.
// • Client profanity screen is a soft nudge, not a block. Replace `ProfanityScreen.bad` via RemoteConfig or bundled JSON.
// • Idempotency: the service must dedupe (itemId, userId, sha256(text), key) to avoid duplicate posts on retries.
// • A11y: list rows are combined elements; “Send” button and “Close” are ≥44pt; bottom sheet supports Dynamic Type.

// MARK: - Test plan (unit/UI)
// Unit:
// 1) Initial load: fetchFirstPage returns items + token → list shows items; token stored.
// 2) Infinite scroll: scroll near end → fetchNextPage merges without duplicates.
// 3) Post success: profanity flagged sets `showProfanityHint == true` on first attempt → second attempt posts.
// 4) Post idempotency: simulate failure, retry with same key → service returns one server item; temp removed.
// 5) Delete: own comment removed optimistically; failure restores.
// 6) Report: calling `report()` sets info toast; error path sets error toast.
// UI:
// • Snapshot at AX sizes; input field grows up to 4 lines; buttons ≥44pt.
// • VoiceOver reads each row: “Name. 2h ago. Text…”. Context menu offers Delete for own, Report for others.


