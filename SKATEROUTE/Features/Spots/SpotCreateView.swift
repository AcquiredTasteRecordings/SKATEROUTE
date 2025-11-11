// Features/Spots/SpotCreateView.swift
// Add spot flow: guided, fast, and accessible.
// - Category picker (icons from our taxonomy), name, optional notes, photo picker, location picker.
// - Permission hints (Photos/Location) with inline guidance; safe fallbacks.
// - Integrates with Services/Spots/SpotStore (create draft → upsert) and UploadService for EXIF-sanitized photo.
// - A11y: Dynamic Type, ≥44pt targets, VO labels; high-contrast safe.
// - Privacy: no auto location grab without user action; no EXIF; no trackers.
// - Offline: queues create if remote unavailable; immediate local insert with “Pending” badge (handled by store).

import SwiftUI
import Combine
import MapKit
import PhotosUI
import UIKit

// MARK: - Models (align with SpotStore)

public enum SpotCreateCategory: String, CaseInsensitiveStringEnumeration, CaseIterable, Sendable {
    case park, plaza, ledge, rail, bowl, DIY, shop, other

    var title: String {
        switch self {
        case .park: return NSLocalizedString("Skatepark", comment: "")
        case .plaza: return NSLocalizedString("Plaza", comment: "")
        case .ledge: return NSLocalizedString("Ledges", comment: "")
        case .rail:  return NSLocalizedString("Rails", comment: "")
        case .bowl:  return NSLocalizedString("Bowls", comment: "")
        case .DIY:   return NSLocalizedString("DIY", comment: "")
        case .shop:  return NSLocalizedString("Shop", comment: "")
        case .other: return NSLocalizedString("Other", comment: "")
        }
    }

    var symbol: String {
        switch self {
        case .park:  return "figure.skating"
        case .plaza: return "building.2"
        case .ledge: return "rectangle.split.3x1"
        case .rail:  return "line.diagonal"
        case .bowl:  return "circle.grid.2x2"
        case .DIY:   return "hammer"
        case .shop:  return "bag"
        case .other: return "mappin"
        }
    }
}

public struct SpotDraft: Sendable, Equatable {
    public var name: String
    public var category: SpotCreateCategory
    public var coordinate: CLLocationCoordinate2D?
    public var notes: String?
    public var photo: UIImage?
    public init(name: String = "",
                category: SpotCreateCategory = .plaza,
                coordinate: CLLocationCoordinate2D? = nil,
                notes: String? = nil,
                photo: UIImage? = nil) {
        self.name = name
        self.category = category
        self.coordinate = coordinate
        self.notes = notes
        self.photo = photo
    }
}

// MARK: - DI seams

public protocol SpotCreating: AnyObject {
    /// Creates the spot (local-first, remote later). Returns new spot id.
    func create(creatorUserId: String, draft: SpotDraft) async throws -> String
}

public protocol LocationPicking: AnyObject {
    /// Presents a location picker; returns coordinate or nil if canceled.
    func pickCoordinate(initial: CLLocationCoordinate2D?) async -> CLLocationCoordinate2D?
}

public protocol UploadServicing {
    /// Strips EXIF & geo; returns CDN URL. (Reusing existing protocol from avatar uploads.)
    func uploadAvatarSanitized(data: Data, key: String, contentType: String) async throws -> URL
}

public protocol AnalyticsLogging {
    func log(_ event: AnalyticsEvent)
}
public struct AnalyticsEvent: Sendable, Hashable {
    public enum Category: String, Sendable { case spots }
    public let name: String
    public let category: Category
    public let params: [String: AnalyticsValue]
    public init(name: String, category: Category, params: [String: AnalyticsValue]) {
        self.name = name; self.category = category; self.params = params
    }
}
public enum AnalyticsValue: Sendable, Hashable { case string(String), int(Int), bool(Bool) }

// MARK: - ViewModel

@MainActor
public final class SpotCreateViewModel: ObservableObject {
    // Form fields
    @Published public var draft = SpotDraft()
    @Published public var selectedItem: PhotosPickerItem? // for PhotosPicker
    @Published public var photoPermissionStatus: PHAuthorizationStatus = .notDetermined

    // State
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var canSubmit = false
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?
    @Published public var showLocationHint = false
    @Published public var showPhotoPermissionHint = false

    // DI
    private let creator: SpotCreating
    private let uploader: UploadServicing
    private let locationPicker: LocationPicking
    private let analytics: AnalyticsLogging?
    private let userIdProvider: () -> String

    public init(creator: SpotCreating,
                uploader: UploadServicing,
                locationPicker: LocationPicking,
                analytics: AnalyticsLogging?,
                userIdProvider: @escaping () -> String) {
        self.creator = creator
        self.uploader = uploader
        self.locationPicker = locationPicker
        self.analytics = analytics
        self.userIdProvider = userIdProvider
        validate()
    }

    public func onAppear() {
        validate()
        Task { @MainActor in
            self.photoPermissionStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
    }

    public func pickLocation() {
        Task {
            let picked = await locationPicker.pickCoordinate(initial: draft.coordinate)
            if let c = picked {
                draft.coordinate = c
                showLocationHint = false
                validate()
            } else {
                // User canceled; keep state
            }
        }
    }

    public func pickPhoto(_ item: PhotosPickerItem?) {
        selectedItem = item
        guard let item else { return }
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    // Downscale aggressively to 1920px long edge to bound upload/time
                    draft.photo = img.downscaled(maxLongEdge: 1920)
                    validate()
                }
            } catch {
                errorMessage = NSLocalizedString("Couldn’t load that photo.", comment: "photo fail")
            }
        }
    }

    public func submit() {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        analytics?.log(.init(name: "spot_create_attempt", category: .spots, params: [:]))
        Task {
            do {
                var toUploadURL: URL? = nil
                if let image = draft.photo, let jpeg = image.jpegData(compressionQuality: 0.85) {
                    // Use avatar uploader for sanitized (we document the contract to strip EXIF).
                    toUploadURL = try await uploader.uploadAvatarSanitized(
                        data: jpeg,
                        key: "spots/\(UUID().uuidString)",
                        contentType: "image/jpeg"
                    )
                }

                var clean = draft
                // Swap local photo with placeholder (server binds CDN later); we don’t embed URLs here.
                if toUploadURL != nil { clean.photo = nil }

                let id = try await creator.create(creatorUserId: userIdProvider(), draft: clean)
                isSubmitting = false
                infoMessage = NSLocalizedString("Spot submitted! Thanks for contributing.", comment: "ok")
                analytics?.log(.init(name: "spot_create_success", category: .spots,
                                      params: ["id": .string(id), "cat": .string(clean.category.rawValue)]))
                // Reset form for next add
                draft = SpotDraft()
                selectedItem = nil
                validate()
            } catch {
                isSubmitting = false
                errorMessage = NSLocalizedString("Couldn’t add spot. You can try again later.", comment: "create fail")
            }
        }
    }

    // MARK: - Validation

    public func validate() {
        let nameOK = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
        let locOK = draft.coordinate != nil
        canSubmit = nameOK && locOK
        showLocationHint = !locOK
    }

    // MARK: - Permissions

    public func requestPhotoAccessIfNeeded() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            showPhotoPermissionHint = false
        case .denied, .restricted:
            showPhotoPermissionHint = true
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                Task { @MainActor in
                    self?.photoPermissionStatus = status
                    self?.showPhotoPermissionHint = (status == .denied || status == .restricted)
                }
            }
        @unknown default:
            break
        }
    }
}

// MARK: - View

public struct SpotCreateView: View {
    @ObservedObject private var vm: SpotCreateViewModel

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207),
        span: .init(latitudeDelta: 0.03, longitudeDelta: 0.03)
    )

    public init(viewModel: SpotCreateViewModel) { self.vm = viewModel }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                titleHeader
                categoryPicker
                nameField
                locationSection
                photoSection
                notesField
                submitCTA
                footerDisclaimer
            }
            .padding(16)
        }
        .navigationTitle(Text(NSLocalizedString("Add Spot", comment: "title")))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.onAppear() }
        .overlay(toastOverlay)
        .accessibilityElement(children: .contain)
    }

    // MARK: Header

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("Put a good spot on the map", comment: "header"))
                .font(.title2.weight(.bold))
            Text(NSLocalizedString("Share the love. Keep it respectful—no secret DIYs without community consent.", comment: "sub"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Category picker

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Category", comment: "category")).font(.headline)
            LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(SpotCreateCategory.allCases, id: \.self) { cat in
                    Button {
                        vm.draft.category = cat
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: cat.symbol)
                                .imageScale(.large)
                            Text(cat.title).font(.footnote).multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(vm.draft.category == cat ? .accentColor : .gray.opacity(0.25))
                    .accessibilityLabel(Text(cat.title))
                }
            }
        }
    }

    // MARK: Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("Name", comment: "name")).font(.headline)
            TextField(NSLocalizedString("e.g., Olympic Plaza ledges", comment: "placeholder"), text: $vm.draft.name)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .accessibilityIdentifier("spot_name")
        }
    }

    // MARK: Location (guided picker + hint)

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("Location", comment: "loc")).font(.headline)
                Spacer()
                Button {
                    vm.pickLocation()
                } label: {
                    Label(NSLocalizedString("Pick on map", comment: "pick"), systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("spot_pick_location")
            }

            ZStack(alignment: .topLeading) {
                MapSnapshotPreview(coordinate: vm.draft.coordinate ?? region.center)
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                if vm.draft.coordinate == nil {
                    Text(NSLocalizedString("No location set", comment: "noloc"))
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }

            if vm.showLocationHint {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").imageScale(.medium)
                    Text(NSLocalizedString("Tap “Pick on map” to drop a pin. We don’t read your location automatically.", comment: "loc hint"))
                        .font(.footnote)
                }
                .padding(8)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: Photo

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Photo (optional)", comment: "photo")).font(.headline)

            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12))
                        .frame(width: 120, height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    if let img = vm.draft.photo {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: 120, height: 90).clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(selection: Binding(get: { vm.selectedItem }, set: vm.pickPhoto),
                                 matching: .images,
                                 photoLibrary: .shared()) {
                        Label(NSLocalizedString("Choose from library", comment: "choose"), systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("spot_pick_photo")

                    if vm.showPhotoPermissionHint {
                        Button {
                            // Open Settings
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label(NSLocalizedString("Enable Photos access in Settings", comment: "enable"), systemImage: "gearshape")
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    }
                }
            }

            Text(NSLocalizedString("No faces or license plates. Be chill with local rules.", comment: "photo rules"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onAppear { vm.requestPhotoAccessIfNeeded() }
    }

    // MARK: Notes

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("Tips / access notes (optional)", comment: "notes")).font(.headline)
            TextField(NSLocalizedString("e.g., Best after 6pm. Watch for security.", comment: "notes placeholder"),
                      text: Binding(get: { vm.draft.notes ?? "" }, set: { vm.draft.notes = $0 }),
                      axis: .vertical)
                .lineLimit(2...5)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .accessibilityIdentifier("spot_notes")
        }
    }

    // MARK: Submit

    private var submitCTA: some View {
        Button(action: vm.submit) {
            if vm.isSubmitting {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 14)
            } else {
                Label(NSLocalizedString("Submit Spot", comment: "submit"), systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!vm.canSubmit || vm.isSubmitting)
        .frame(minHeight: 54)
        .accessibilityIdentifier("spot_submit")
    }

    private var footerDisclaimer: some View {
        Text(NSLocalizedString("By submitting, you confirm this spot is public-access and safe to share. We’ll hide exact locations if flagged by the community.", comment: "disclaimer"))
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    // MARK: Toasts

    @ViewBuilder
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if let msg = vm.errorMessage {
                toast(text: msg, system: "exclamationmark.triangle.fill", bg: .red)
                    .onAppear { autoDismiss { vm.errorMessage = nil } }
            } else if let info = vm.infoMessage {
                toast(text: info, system: "checkmark.seal.fill", bg: .green)
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

// MARK: - Map snapshot preview (non-interactive to keep UI cheap)

fileprivate struct MapSnapshotPreview: View {
    let coordinate: CLLocationCoordinate2D
    var body: some View {
        Map(initialPosition: .region(.init(center: coordinate, span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)))) {
            Annotation("", coordinate: coordinate) {
                ZStack {
                    Circle().fill(Color.red).frame(width: 18, height: 18)
                    Circle().strokeBorder(Color.white, lineWidth: 2).frame(width: 18, height: 18)
                }
                .accessibilityHidden(true)
            }
        }
        .disabled(true)
    }
}

// MARK: - Utilities

fileprivate extension UIImage {
    func downscaled(maxLongEdge: CGFloat) -> UIImage {
        let size = self.size
        let long = max(size.width, size.height)
        guard long > maxLongEdge else { return self }
        let scale = maxLongEdge / long
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in self.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

// MARK: - Convenience builder

public extension SpotCreateView {
    static func make(creator: SpotCreating,
                     uploader: UploadServicing,
                     locationPicker: LocationPicking,
                     analytics: AnalyticsLogging? = nil,
                     userIdProvider: @escaping () -> String) -> SpotCreateView {
        SpotCreateView(viewModel: .init(creator: creator,
                                        uploader: uploader,
                                        locationPicker: locationPicker,
                                        analytics: analytics,
                                        userIdProvider: userIdProvider))
    }
}

// MARK: - DEBUG fakes

#if DEBUG
private final class CreatorFake: SpotCreating {
    func create(creatorUserId: String, draft: SpotDraft) async throws -> String { UUID().uuidString }
}
private final class UploadFake: UploadServicing {
    func uploadAvatarSanitized(data: Data, key: String, contentType: String) async throws -> URL {
        URL(string: "https://cdn.skateroute.app/\(key).jpg")!
    }
}
private final class LocationPickerFake: LocationPicking {
    func pickCoordinate(initial: CLLocationCoordinate2D?) async -> CLLocationCoordinate2D? {
        // Pretend user picked a point near initial or downtown Vancouver
        initial ?? CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207)
    }
}

struct SpotCreateView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SpotCreateView.make(creator: CreatorFake(),
                                uploader: UploadFake(),
                                locationPicker: LocationPickerFake(),
                                userIdProvider: { "me" })
        }
        .preferredColorScheme(.dark)
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}
#endif

// MARK: - Integration notes
// • Wire `SpotCreating` to Services/Spots/SpotStore.addSpot(draft:) which should:
//     - Create a local SwiftData Spot with status .pending, publish to map/feed,
//     - Upload sanitized photo (we used UploadServicing stub above; real impl should move this server-side),
//     - Sync to backend with trust-weight bootstrap; when confirmed, flip status .active.
// • `LocationPicking` may push a lightweight map picker screen (single-drop pin, search address optional) and return coordinate.
// • Telemetry: use AnalyticsLogger façade; record generic add attempt/success/fail; never log coordinates or text.
// • Permissions: Photos access is optional; if denied, show Settings CTA; do not nag repeatedly.
// • A11y: all controls ≥44pt; “Pick on map” & “Submit Spot” have identifiers for UITests.

// MARK: - Test plan (unit/UI)
// Unit:
// 1) Validation: name <3 chars → canSubmit=false; set coordinate → canSubmit true.
// 2) Submit path success: creator returns id → infoMessage set, draft resets, isSubmitting toggles as expected.
// 3) Submit path failure: errorMessage set; draft unchanged.
// 4) Photo processing: JPEG downscale reduces long edge to ≤1920; EXIF is not preserved by uploader contract.
// UI:
// 1) Denied Photos → Settings hint visible; authorized → hidden.
// 2) Location hint visible until coordinate picked; after pick, snapshot shows pin.
// 3) Dynamic Type XXL → grid wraps; buttons remain ≥44pt; VO labels read category/title.
// 4) UITest IDs: spot_name, spot_pick_location, spot_pick_photo, spot_notes, spot_submit.
