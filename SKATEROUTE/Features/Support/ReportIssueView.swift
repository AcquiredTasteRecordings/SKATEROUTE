// Features/Support/ReportIssueView.swift
// Feedback composer with live, redacted log snippets.
// - Streams recent SessionLogger lines (ring buffer) for context while user types.
// - One-tap “Include logs” uses Support/Feedback/Redactor to scrub PII and writes a temp bundle.
// - Attachments: redacted logs + optional diagnostics.txt (MetricKitService), both ephemeral.
// - Submission: share sheet (mail, Files, Messages) or pluggable backend uploader.
// - Privacy-first: contact field is optional; no hidden tracking. We never upload automatically without an explicit user action.
// - A11y: Dynamic Type, ≥44pt, VO labels. Localized copy.
//
// Integration points:
// • SessionLogger → LogStreaming adapter providing AsyncSequence<String> or Combine publisher.
// • Redactor → scrubs PII from logs and small text fields. MUST handle email/phone/URLs and coordinates.
// • MetricKitService (optional) → emits a redacted diagnostics summary for attachment.
// • UploadService (optional) → background upload path if you wire IssueSubmitting to backend.

import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit

// MARK: - Domain adapters

public enum IssueKind: String, CaseIterable, Identifiable, Sendable {
    case bug
    case mapData
    case hazard
    case idea
    case other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .bug: return NSLocalizedString("Bug", comment: "issue kind")
        case .mapData: return NSLocalizedString("Map / Route", comment: "issue kind")
        case .hazard: return NSLocalizedString("Hazard", comment: "issue kind")
        case .idea: return NSLocalizedString("Feature idea", comment: "issue kind")
        case .other: return NSLocalizedString("Other", comment: "issue kind")
        }
    }
}

public protocol LogStreaming: AnyObject {
    /// Live stream of recent log lines (already non-sensitive where possible).
    var linesPublisher: AnyPublisher<String, Never> { get }
    /// Snapshot last N lines synchronously for quick preview.
    func ringBufferSnapshot(maxLines: Int) -> [String]
    /// Export raw session logs to a temporary file (unredacted). Caller must redactor.scrub(file:).
    func exportRawLogFile() throws -> URL
}

public protocol Redacting: AnyObject {
    /// Returns a new temp file URL with redacted contents.
    func scrub(file url: URL) throws -> URL
    /// Scrubs small strings (description/contact) inline.
    func scrub(text: String) -> String
}

public protocol DiagnosticsSummarizing: AnyObject {
    /// Optional. Exports a short redacted diagnostics summary (battery/gps budgets, versions).
    func exportDiagnostics() async throws -> URL
}

public struct IssueAttachment: Equatable, Sendable {
    public let name: String
    public let url: URL
    public init(name: String, url: URL) { self.name = name; self.url = url }
}

public protocol IssueSubmitting: AnyObject {
    /// If provided, can upload the issue bundle in the background.
    /// Return an URL to a support ticket or nil to fall back to share sheet.
    func submit(kind: IssueKind,
                description: String,
                contact: String?,
                attachments: [IssueAttachment]) async throws -> URL?
}

public protocol AnalyticsLogging {
    func log(_ event: AnalyticsEvent)
}
public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable { case support }
    public let name: String
    public let category: Category
    public let params: [String: AnalyticsValue]
    public init(name: String, category: Category, params: [String: AnalyticsValue]) { self.name = name; self.category = category; self.params = params }
}
public enum AnalyticsValue: Sendable, Hashable { case string(String), int(Int), bool(Bool), double(Double) }

// MARK: - ViewModel

@MainActor
public final class ReportIssueViewModel: ObservableObject {
    @Published public var kind: IssueKind = .bug
    @Published public var descriptionText: String = ""
    @Published public var contactText: String = ""
    @Published public var includeLogs: Bool = true
    @Published public var includeDiagnostics: Bool = true
    @Published public private(set) var liveLines: [String] = []
    @Published public private(set) var preparing = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var infoMessage: String?
    @Published public private(set) var shareItems: [Any] = [] // triggers ShareSheet when non-empty

    private let logs: LogStreaming
    private let redactor: Redacting
    private let diag: DiagnosticsSummarizing?
    private let submitter: IssueSubmitting?
    private let analytics: AnalyticsLogging?
    private var cancellables = Set<AnyCancellable>()
    private let ringSize: Int = 60

    public init(logs: LogStreaming,
                redactor: Redacting,
                diagnostics: DiagnosticsSummarizing? = nil,
                submitter: IssueSubmitting? = nil,
                analytics: AnalyticsLogging? = nil) {
        self.logs = logs
        self.redactor = redactor
        self.diag = diagnostics
        self.submitter = submitter
        self.analytics = analytics
        bootstrap()
    }

    private func bootstrap() {
        // Seed with recent lines for immediate context.
        liveLines = logs.ringBufferSnapshot(maxLines: ringSize)
        // Stream live lines, cap to ringSize.
        logs.linesPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] line in
                guard let self else { return }
                self.liveLines.append(line)
                if self.liveLines.count > self.ringSize { self.liveLines.removeFirst(self.liveLines.count - self.ringSize) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Compose & Submit

    public func previewShareItems() async {
        do {
            let bundle = try await prepareBundle()
            shareItems = bundle
        } catch {
            errorMessage = NSLocalizedString("Couldn’t prepare attachments.", comment: "prep fail")
        }
    }

    public func submit() {
        Task {
            preparing = true
            defer { preparing = false }
            do {
                let attachments = try await buildAttachments()
                // Prefer backend submit if available; else surface share sheet.
                if let submitter, let url = try await submitter.submit(kind: kind,
                                                                       description: redactor.scrub(text: descriptionText),
                                                                       contact: redactor.scrub(text: contactText).nilIfEmpty(),
                                                                       attachments: attachments) {
                    infoMessage = NSLocalizedString("Thanks! Your report was submitted.", comment: "submit ok")
                    analytics?.log(.init(name: "issue_submit_backend", category: .support, params: ["kind": .string(kind.rawValue)]))
                    // Offer a share link as fallback (copy to pasteboard)
                    UIPasteboard.general.url = url
                } else {
                    // Share sheet path
                    shareItems = try await prepareBundle()
                    analytics?.log(.init(name: "issue_share_open", category: .support, params: ["kind": .string(kind.rawValue)]))
                }
            } catch {
                errorMessage = NSLocalizedString("Submission failed. Try sharing via Mail instead.", comment: "submit fail")
            }
        }
    }

    // MARK: - Internals

    private func prepareBundle() async throws -> [Any] {
        let attachments = try await buildAttachments()
        let subject = "[SkateRoute] \(kind.label) – \(shortDescription())"
        let body = """
        \(kind.label) report

        \(redactor.scrub(text: descriptionText))

        \(contactSection())
        """
        var items: [Any] = [subject, body]
        attachments.forEach { items.append($0.url) }
        return items
    }

    private func buildAttachments() async throws -> [IssueAttachment] {
        preparing = true
        defer { preparing = false }
        var attachments: [IssueAttachment] = []

        if includeLogs {
            let raw = try logs.exportRawLogFile()
            let red = try redactor.scrub(file: raw)
            attachments.append(.init(name: "logs-redacted.ndjson", url: red))
        }
        if includeDiagnostics, let diag {
            do {
                let d = try await diag.exportDiagnostics()
                attachments.append(.init(name: "diagnostics.txt", url: d))
            } catch {
                // Non-fatal – skip diagnostics if unavailable
            }
        }
        // Always attach a small context.txt with meta (no PII).
        let ctx = try makeContextFile()
        attachments.append(.init(name: "context.txt", url: ctx))

        return attachments
    }

    private func makeContextFile() throws -> URL {
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current.model
        let os = UIDevice.current.systemVersion
        let text =
        """
        app_version=\(app)
        build=\(build)
        device=\(device)
        ios=\(os)
        issue_kind=\(kind.rawValue)
        timestamp=\(ISO8601DateFormatter().string(from: Date()))
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("context.txt")
        try text.data(using: .utf8)!.write(to: url)
        return url
    }

    private func shortDescription(max: Int = 48) -> String {
        let s = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > max else { return s }
        let end = s.index(s.startIndex, offsetBy: max)
        return String(s[..<end]) + "…"
    }

    private func contactSection() -> String {
        let c = contactText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else {
            return NSLocalizedString("No contact provided (optional).", comment: "contact none")
        }
        return String(format: NSLocalizedString("Contact: %@", comment: "contact provided"), redactor.scrub(text: c))
    }
}

// MARK: - View

public struct ReportIssueView: View {
    @ObservedObject private var vm: ReportIssueViewModel
    @State private var presentShare = false

    public init(viewModel: ReportIssueViewModel) { self.vm = viewModel }

    public var body: some View {
        List {
            kindSection
            describeSection
            attachSection
            previewSection
            submitSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(NSLocalizedString("Report an issue", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $presentShare) {
            ShareSheet(activityItems: vm.shareItems)
                .onDisappear { vm.shareItems = [] }
        }
        .onChange(of: vm.shareItems) { presentShare = !$0.isEmpty }
        .overlay(toasts, alignment: .bottom)
        .accessibilityIdentifier("report_issue_root")
    }

    // MARK: Sections

    private var kindSection: some View {
        Section(header: header(NSLocalizedString("What’s up?", comment: "kind"))) {
            Picker(selection: $vm.kind) {
                ForEach(IssueKind.allCases) { k in
                    Text(k.label).tag(k)
                }
            } label: { Text(NSLocalizedString("Issue type", comment: "issue type")) }
            .pickerStyle(.menu)
            .accessibilityIdentifier("issue_kind_picker")
        }
    }

    private var describeSection: some View {
        Section(header: header(NSLocalizedString("Describe the problem", comment: "desc")),
                footer: Text(NSLocalizedString("Please avoid sharing personal details. We’ll strip obvious PII before sending.", comment: "desc foot")).font(.footnote)) {

            TextEditor(text: $vm.descriptionText)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                .accessibilityIdentifier("issue_text")

            HStack(spacing: 8) {
                Image(systemName: "at").accessibilityHidden(true)
                TextField(NSLocalizedString("Contact (optional email or handle)", comment: "contact"), text: $vm.contactText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .disableAutocorrection(true)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06)))
            .accessibilityIdentifier("contact_field")
        }
    }

    private var attachSection: some View {
        Section(header: header(NSLocalizedString("Attachments", comment: "attachments")),
                footer: Text(NSLocalizedString("Logs and diagnostics are redacted on-device before sharing.", comment: "attach foot")).font(.footnote)) {
            Toggle(isOn: $vm.includeLogs) {
                Label(NSLocalizedString("Include logs (recommended)", comment: "logs"), systemImage: "doc.plaintext")
            }
            .accessibilityIdentifier("include_logs_toggle")

            Toggle(isOn: $vm.includeDiagnostics) {
                Label(NSLocalizedString("Include diagnostics", comment: "diags"), systemImage: "stethoscope")
            }
            .accessibilityIdentifier("include_diag_toggle")
        }
    }

    private var previewSection: some View {
        Section(header: header(NSLocalizedString("Recent activity (preview)", comment: "preview")),
                footer: Text(NSLocalizedString("This is a short preview. Full logs are attached only if enabled.", comment: "preview foot")).font(.footnote)) {
            LogPreview(lines: vm.liveLines)
                .frame(minHeight: 120)
                .accessibilityIdentifier("log_preview")
            HStack {
                Button {
                    Task { await vm.previewShareItems() }
                } label: {
                    Label(NSLocalizedString("Preview share", comment: "preview"), systemImage: "eye")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
    }

    private var submitSection: some View {
        Section {
            Button(action: vm.submit) {
                if vm.preparing {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 22)
                } else {
                    Label(NSLocalizedString("Send", comment: "send"), systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .disabled(vm.preparing || vm.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("send_button")
        }
    }

    // MARK: UI atoms

    private func header(_ title: String) -> some View {
        HStack { Text(title).font(.subheadline.weight(.semibold)); Spacer() }.accessibilityHidden(true)
    }

    @ViewBuilder
    private var toasts: some View {
        VStack {
            if let e = vm.errorMessage {
                toast(text: e, system: "exclamationmark.triangle.fill", bg: .red)
                    .onAppear { autoDismiss { vm.errorMessage = nil } }
            } else if let i = vm.infoMessage {
                toast(text: i, system: "checkmark.seal.fill", bg: .green)
                    .onAppear { autoDismiss { vm.infoMessage = nil } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut, value: vm.errorMessage != nil || vm.infoMessage != nil)
    }

    private func toast(text: String, system: String, bg: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: system).imageScale(.large).accessibilityHidden(true)
            Text(text).font(.callout).multilineTextAlignment(.leading)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundColor(.white)
    }

    private func autoDismiss(_ body: @escaping () -> Void) {
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); await MainActor.run(body) }
    }
}

// MARK: - Log preview

fileprivate struct LogPreview: View {
    let lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.suffix(120).enumerated()), id: \.offset) { _, l in
                        Text(l)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { _ in
                // autoscroll to bottom (best-effort)
                withAnimation { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            }
        }
    }
}

// MARK: - ShareSheet (UIKit bridge)

fileprivate struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Small convenience

fileprivate extension String {
    func nilIfEmpty() -> String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - DEBUG fakes

#if DEBUG
final class LogStreamFake: LogStreaming {
    private let subject = PassthroughSubject<String, Never>()
    private var timer: AnyCancellable?
    init() {
        // emit a fake line every 0.7s
        timer = Timer.publish(every: 0.7, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.subject.send("INFO route:update grade=3 surface=good ts=\(Int(Date().timeIntervalSince1970))")
            }
    }
    var linesPublisher: AnyPublisher<String, Never> { subject.eraseToAnyPublisher() }
    func ringBufferSnapshot(maxLines: Int) -> [String] {
        (0..<min(maxLines, 8)).map { i in "DEBUG boot step=\(i)" }
    }
    func exportRawLogFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("raw.ndjson")
        try (0..<30).map { "L\($0)\n" }.joined().data(using: .utf8)!.write(to: url)
        return url
    }
}

final class RedactorFake: Redacting {
    func scrub(file url: URL) throws -> URL {
        // Pretend to redact by copying
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("logs-redacted.ndjson")
        let data = try Data(contentsOf: url)
        try data.replacingOccurrences(of: "DEBUG", with: "DBG").write(to: out)
        return out
    }
    func scrub(text: String) -> String {
        text.replacingOccurrences(of: "@", with: "[at]")
    }
}

final class DiagFake: DiagnosticsSummarizing {
    func exportDiagnostics() async throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diagnostics.txt")
        try """
        gps_median_drift_m=6
        nav_burn_pct_hr=6.5
        reroute_p95_ms=82
        """.data(using: .utf8)!.write(to: url)
        return url
    }
}

final class SubmitterFake: IssueSubmitting {
    func submit(kind: IssueKind, description: String, contact: String?, attachments: [IssueAttachment]) async throws -> URL? {
        // Return nil to force share sheet in preview
        return nil
    }
}

public struct ReportIssueView_Previews: PreviewProvider {
    public static var previews: some View {
        NavigationView {
            ReportIssueView(
                viewModel: .init(logs: LogStreamFake(),
                                 redactor: RedactorFake(),
                                 diagnostics: DiagFake(),
                                 submitter: SubmitterFake(),
                                 analytics: nil)
            )
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire LogStreaming to your SessionLogger (already added in prior commits). Ensure exportRawLogFile() writes the current session’s
//   NDJSON to a temp URL; if logging is still open, flush before export.
// • Redactor must aggressively scrub: email/phone/URLs, tokens, coarse location (±250 m), device identifiers, and partner codes.
//   Implement using Support/Feedback/Redactor.swift shared utilities. Always output UTF-8 text files.
// • DiagnosticsSummarizing should call Services/Crash/MetricKitService.exportRedactedLog() or a short summary builder.
// • IssueSubmitting backend path (optional): POST a multipart form to your support endpoint with “kind”, “description”, optional “contact”,
//   and attachments. Use UploadService background tasks if uploads are large. Return a ticket/deeplink URL for user reference.
// • ShareSheet path is the default to keep user in control. Subject+body come first in activityItems so Mail picks them up.
// • UITests: fill description, toggle logs/diags, tap “Preview share” → sheet; tap “Send” with SubmitterFake(nil) → sheet opens.
// • Accessibility: identifiers “report_issue_root”, “issue_kind_picker”, “issue_text”, “include_logs_toggle”, “include_diag_toggle”, “send_button”.


