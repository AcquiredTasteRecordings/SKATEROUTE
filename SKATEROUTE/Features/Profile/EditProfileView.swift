// Features/Profile/EditProfileView.swift
// Edit profile: display name, avatar, privacy options.
// - Friendly guardrails: local uniqueness check (debounced), soft profanity screen, length + charset validation.
// - Avatar picker via PHPicker; UploadService sanitizes EXIF server-side by contract (validated in UserProfileStore).
// - Privacy toggles (hide city / hide routes) that write through to UserProfileStore.
// - A11y: Dynamic Type, ≥44pt targets, explicit VO labels/hints, high-contrast safe.
// - No tracking. Optional Analytics façade logs only generic taps (no PII).

import SwiftUI
import Combine
import PhotosUI
import UIKit

// MARK: - DI seams (narrow & testable)

public protocol ProfileEditing: AnyObject {
    // Backed by Services/Profile/UserProfileStore
    var currentUserId: String { get }
    var profilePublisher: AnyPublisher<UserProfileEditable, Never> { get }
    func load(userId: String) async
    func update(id: String, displayName: String?, city: String?, hideCity: Bool?, hideRoutes: Bool?) async
    func setAvatar(userId: String, imageData: Data, contentType: String) async
}

public struct UserProfileEditable: Equatable, Sendable {
    public let id: String
    public var displayName: String
    public var city: String?
    public var avatarURL: URL?
    public var hideCity: Bool
    public var hideRoutes: Bool
}

public protocol LocalHandleIndexing: AnyObject {
    /// Local-only uniqueness check (SwiftData/SQLite index); case-insensitive, trimmed.
    func isDisplayNameAvailableLocally(_ normalized: String) -> Bool
}

public protocol RemoteHandleValidating: AnyObject {
    /// Optional remote availability check (only called if local check passes), debounced.
    func isDisplayNameAvailableRemotely(_ normalized: String) async -> Bool
}

public protocol AnalyticsLogging {
    func log(_ event: AnalyticsEvent)
}
public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable { case profile }
    public let name: String
    public let category: Category
    public let params: [String: AnalyticsValue]
    public init(name: String, category: Category, params: [String: AnalyticsValue]) {
        self.name = name; self.category = category; self.params = params
    }
}
public enum AnalyticsValue: Sendable, Hashable { case string(String), bool(Bool) }

// MARK: - ViewModel

@MainActor
public final class EditProfileViewModel: ObservableObject {

    @Published public private(set) var userId: String
    @Published public var displayName: String = ""
    @Published public var city: String = ""
    @Published public var hideCity: Bool = false
    @Published public var hideRoutes: Bool = false

    @Published public private(set) var avatarURL: URL?
    @Published public var pickedItem: PhotosPickerItem?
    @Published public private(set) var isSaving = false
    @Published public private(set) var isUploading = false

    @Published public private(set) var nameValidation: NameValidation = .idle
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?

    public enum NameValidation: Equatable {
        case idle
        case checking
        case available
        case unavailable(reason: String) // reason is user-friendly + localized
    }

    // DI
    private let store: ProfileEditing
    private let index: LocalHandleIndexing
    private let remoteCheck: RemoteHandleValidating?
    private let analytics: AnalyticsLogging?

    // Streams
    private var cancellables = Set<AnyCancellable>()
    private let nameSubject = PassthroughSubject<String, Never>()

    // Rules
    private let minLen = 2
    private let maxLen = 24

    public init(store: ProfileEditing,
                index: LocalHandleIndexing,
                remoteCheck: RemoteHandleValidating?,
                analytics: AnalyticsLogging? = nil) {
        self.store = store
        self.index = index
        self.remoteCheck = remoteCheck
        self.analytics = analytics
        self.userId = store.currentUserId
        bind()
    }

    private func bind() {
        store.profilePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] p in
                guard let self else { return }
                self.userId = p.id
                self.displayName = p.displayName
                self.city = p.city ?? ""
                self.avatarURL = p.avatarURL
                self.hideCity = p.hideCity
                self.hideRoutes = p.hideRoutes
                self.nameValidation = .idle
            }
            .store(in: &cancellables)

        // Debounced validation pipeline
        nameSubject
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] name in
                Task { await self?.validateName(name) }
            }
            .store(in: &cancellables)
    }

    public func onAppear() {
        Task { await store.load(userId: userId) }
    }

    public func onNameChange(_ s: String) {
        nameSubject.send(s)
    }

    public func save() {
        guard case .available = nameValidation || nameValidation == .idle else {
            errorMessage = NSLocalizedString("Choose a different name.", comment: "name unavailable")
            return
        }
        isSaving = true
        analytics?.log(.init(name: "profile_save", category: .profile, params: [:]))
        Task {
            defer { isSaving = false }
            await store.update(id: userId,
                               displayName: displayName.trimmedOrNil(),
                               city: city.trimmedOrNil(),
                               hideCity: hideCity,
                               hideRoutes: hideRoutes)
            infoMessage = NSLocalizedString("Profile updated.", comment: "save ok")
        }
    }

    public func handlePickedItem() {
        guard let item = pickedItem else { return }
        Task {
            isUploading = true
            defer { isUploading = false }
            do {
                // Load data (compress to reasonable size if needed)
                if let data = try await dataForPickedItem(item) {
                    await store.setAvatar(userId: userId, imageData: data, contentType: "image/jpeg")
                    infoMessage = NSLocalizedString("Avatar updated.", comment: "avatar ok")
                } else {
                    errorMessage = NSLocalizedString("Couldn’t load that photo.", comment: "avatar fail")
                }
            } catch {
                errorMessage = NSLocalizedString("Avatar upload failed. Try a different image.", comment: "avatar error")
            }
            pickedItem = nil
        }
    }

    // MARK: - Validation

    private func validateName(_ raw: String) async {
        let name = normalized(raw)
        // Short-circuit: unchanged from current
        if name.caseInsensitiveCompare(normalized(displayName)) == .orderedSame, case .idle = nameValidation {
            nameValidation = .idle
            return
        }
        // Syntactic checks
        if name.count < minLen {
            nameValidation = .unavailable(reason: String(format: NSLocalizedString("Too short (min %d).", comment: "too short"), minLen))
            return
        }
        if name.count > maxLen {
            nameValidation = .unavailable(reason: String(format: NSLocalizedString("Too long (max %d).", comment: "too long"), maxLen))
            return
        }
        if !allowedCharset(name) {
            nameValidation = .unavailable(reason: NSLocalizedString("Letters, numbers, spaces, and _-. only.", comment: "charset"))
            return
        }
        if containsProfanity(name) {
            nameValidation = .unavailable(reason: NSLocalizedString("Let’s keep names friendly.", comment: "profanity"))
            return
        }

        nameValidation = .checking

        // Local uniqueness (fast)
        if !index.isDisplayNameAvailableLocally(name) && normalized(displayName) != name {
            nameValidation = .unavailable(reason: NSLocalizedString("Name already taken (local).", comment: "local taken"))
            return
        }

        // Optional remote uniqueness (debounced)
        if let remoteCheck {
            let ok = await remoteCheck.isDisplayNameAvailableRemotely(name)
            await MainActor.run {
                self.nameValidation = ok ? .available : .unavailable(reason: NSLocalizedString("Name already taken.", comment: "remote taken"))
            }
        } else {
            nameValidation = .available
        }
    }

    private func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func allowedCharset(_ s: String) -> Bool {
        // Allow letters, numbers, spaces, underscore, dash, dot
        let pattern = #"^[\p{L}\p{N} _\.-]+$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    private func containsProfanity(_ s: String) -> Bool {
        // Lightweight local screen; full list can come from Resources or RemoteConfig.
        // Keep it minimal and culture-safe; this is a nudge, not a blocklist.
        let bad = ["idiot","dumb","hate"] // placeholder; replace with curated set via RemoteConfig
        let lower = s.lowercased()
        return bad.contains { lower.contains($0) }
    }

    // MARK: - Image helpers

    private func dataForPickedItem(_ item: PhotosPickerItem) async throws -> Data? {
        // Prefer HEIC/JPEG data; compress to ~1080px max dimension
        guard let data = try await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return nil }

        let maxDim: CGFloat = 1080
        let scale = min(1, maxDim / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: target)
        let jpeg = renderer.jpegData(withCompressionQuality: 0.85) { ctx in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return jpeg
    }
}

// MARK: - View

public struct EditProfileView: View {
    @ObservedObject private var vm: EditProfileViewModel

    @Environment(\.dismiss) private var dismiss
    private let corner: CGFloat = 16
    private let buttonH: CGFloat = 54

    public init(viewModel: EditProfileViewModel) { self.vm = viewModel }

    public var body: some View {
        Form {
            avatarSection
            nameSection
            privacySection
            citySection
            saveSection
        }
        .formStyle(.grouped)
        .navigationTitle(Text(NSLocalizedString("Edit Profile", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("Close", comment: "close")) { dismiss() } } }
        .photosPicker(isPresented: Binding(get: { vm.pickedItem != nil }, set: { _ in }),
                      selection: Binding(get: { vm.pickedItem }, set: { vm.pickedItem = $0 }),
                      matching: .images)
        .onChange(of: vm.pickedItem) { _ in vm.handlePickedItem() }
        .onAppear { vm.onAppear() }
        .overlay(toastOverlay)
    }

    // MARK: Sections

    private var avatarSection: some View {
        Section(header: Text(NSLocalizedString("Avatar", comment: "avatar header"))) {
            HStack(spacing: 16) {
                avatarPreview(size: 64)
                    .accessibilityLabel(Text(NSLocalizedString("Current avatar", comment: "")))
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("Choose a friendly photo. No EXIF or location is kept.", comment: "avatar hint"))
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        PhotosPicker(selection: Binding(get: { vm.pickedItem }, set: { vm.pickedItem = $0 }), matching: .images) {
                            Label(NSLocalizedString("Change Photo", comment: "pick"), systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)

                        if vm.isUploading { ProgressView().controlSize(.regular).accessibilityLabel(Text(NSLocalizedString("Uploading", comment: ""))) }
                    }
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func avatarPreview(size: CGFloat) -> some View {
        Group {
            if let url = vm.avatarURL {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: {
                    Color.secondary.opacity(0.15)
                }
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.secondary.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var nameSection: some View {
        Section(header: Text(NSLocalizedString("Display Name", comment: "name header"))) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(NSLocalizedString("Your name", comment: "name placeholder"), text: $vm.displayName)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .submitLabel(.done)
                    .onChange(of: vm.displayName) { vm.onNameChange($0) }
                    .accessibilityLabel(Text(NSLocalizedString("Display name field", comment: "")))

                HStack(spacing: 8) {
                    switch vm.nameValidation {
                    case .idle:
                        Text(NSLocalizedString("2–24 characters. Letters, numbers, spaces, _ - .", comment: "name help"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .checking:
                        ProgressView().controlSize(.small)
                        Text(NSLocalizedString("Checking availability…", comment: "checking")).font(.caption).foregroundStyle(.secondary)
                    case .available:
                        Label(NSLocalizedString("Available", comment: "available"), systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .unavailable(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }
        }
    }

    private var citySection: some View {
        Section(header: Text(NSLocalizedString("City (optional)", comment: "city header"))) {
            TextField(NSLocalizedString("e.g., Vancouver", comment: "city placeholder"), text: $vm.city)
                .textContentType(.addressCity)
                .disableAutocorrection(true)
        }
    }

    private var privacySection: some View {
        Section(header: Text(NSLocalizedString("Privacy", comment: "privacy header")),
                footer: Text(NSLocalizedString("Hiding routes keeps your map private while still sharing videos and badges.", comment: "privacy footer"))) {
            Toggle(isOn: $vm.hideCity) {
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("Hide city on profile", comment: "hide city"))
                    Text(NSLocalizedString("Your city won’t be shown publicly.", comment: "hide city hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("toggle_hide_city")

            Toggle(isOn: $vm.hideRoutes) {
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("Hide routes on profile", comment: "hide routes"))
                    Text(NSLocalizedString("Others won’t see your route list.", comment: "hide routes hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("toggle_hide_routes")
        }
    }

    private var saveSection: some View {
        Section {
            Button(action: vm.save) {
                HStack {
                    if vm.isSaving { ProgressView().controlSize(.regular) }
                    Text(vm.isSaving ? NSLocalizedString("Saving…", comment: "saving") : NSLocalizedString("Save Changes", comment: "save"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: buttonH)
            .disabled(vm.isSaving)
            .accessibilityIdentifier("profile_save")
        }
    }

    // MARK: Toasts

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
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run(body) }
    }
}

// MARK: - Convenience builder

public extension EditProfileView {
    static func make(store: ProfileEditing,
                     index: LocalHandleIndexing,
                     remoteCheck: RemoteHandleValidating?,
                     analytics: AnalyticsLogging? = nil) -> EditProfileView {
        EditProfileView(viewModel: .init(store: store, index: index, remoteCheck: remoteCheck, analytics: analytics))
    }
}

// MARK: - DEBUG fakes (previews)

#if DEBUG
private final class StoreFake: ProfileEditing {
    var currentUserId: String = "u_demo"
    private let subject = CurrentValueSubject<UserProfileEditable, Never>(
        .init(id: "u_demo", displayName: "River", city: "Vancouver", avatarURL: URL(string: "https://picsum.photos/200"), hideCity: false, hideRoutes: false)
    )
    var profilePublisher: AnyPublisher<UserProfileEditable, Never> { subject.eraseToAnyPublisher() }
    func load(userId: String) async {}
    func update(id: String, displayName: String?, city: String?, hideCity: Bool?, hideRoutes: Bool?) async {
        subject.value = .init(id: id,
                              displayName: displayName ?? subject.value.displayName,
                              city: city ?? subject.value.city,
                              avatarURL: subject.value.avatarURL,
                              hideCity: hideCity ?? subject.value.hideCity,
                              hideRoutes: hideRoutes ?? subject.value.hideRoutes)
    }
    func setAvatar(userId: String, imageData: Data, contentType: String) async {}
}
private final class IndexFake: LocalHandleIndexing {
    func isDisplayNameAvailableLocally(_ normalized: String) -> Bool {
        // Block only a specific sample for preview
        return normalized.lowercased() != "taken"
    }
}
private final class RemoteFake: RemoteHandleValidating {
    func isDisplayNameAvailableRemotely(_ normalized: String) async -> Bool {
        // Pretend "river" is taken remotely
        return normalized.lowercased() != "river"
    }
}
private struct AnalyticsNoop: AnalyticsLogging { func log(_ event: AnalyticsEvent) {} }

struct EditProfileView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            EditProfileView.make(store: StoreFake(), index: IndexFake(), remoteCheck: RemoteFake(), analytics: AnalyticsNoop())
        }
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)

        NavigationView {
            EditProfileView.make(store: StoreFake(), index: IndexFake(), remoteCheck: RemoteFake(), analytics: AnalyticsNoop())
        }
        .preferredColorScheme(.dark)
    }
}
#endif

// MARK: - Integration notes
// • Wire `ProfileEditing` to UserProfileStore: expose a read/write adapter that publishes current profile as `UserProfileEditable`.
// • LocalHandleIndexing: implement via SwiftData fetch with case/diacritic-insensitive index on `displayName` (exclude current user).
// • RemoteHandleValidating: implement in your cloud adapter (Firebase/CloudKit) behind RemoteConfig opt-in; only called if local says OK.
// • Avatar uploads: PhotosPicker → vm.handlePickedItem() → UserProfileStore.setAvatar() which calls UploadService.uploadAvatarSanitized.
// • A11y: ≥44pt targets; clear VO labels; Dynamic Type layouts verified via AccessibilityUITests.
// • Privacy: toggles map directly to `hideCity` / `hideRoutes` and affect ProfileView & Feed/Leaderboards visibility.

// MARK: - Test plan (unit / UI)
// Unit:
// 1) Name syntax: “R” → .unavailable(min), “Very very very very long name” → .unavailable(max), “Bad_Idiot” → .unavailable(profanity).
// 2) Local uniqueness: index returns false → .unavailable(local). If equals current (normalized) → allow idle/save.
// 3) Remote: when local passes and Remote returns false → .unavailable(remote); otherwise .available.
// 4) Save flow: when name unavailable → save blocked; when available → calls store.update with mapped fields.
// 5) Avatar: pickedItem data loads → setAvatar called; error path sets errorMessage.
// UI:
// • Snapshot with AX3XL: labels wrap cleanly; CTAs ≥44pt; toasts readable.
// • VO flow: Avatar → Name (with helper) → Privacy toggles → Save → Close.


