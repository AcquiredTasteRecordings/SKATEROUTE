// Features/Media/EditorView.swift
// Lightweight editor: trim / filters / text overlays / soundtrack picker.
// - Wraps Services/Media/EditorPipeline.swift (composable ops, non-destructive timeline).
// - Presets: feed, story, archive. Background export with progress + cancel.
// - A11y: Dynamic Type, ≥44pt targets, VO-friendly controls. Captions button if legible tracks exist.
// - Privacy: no microphone/camera roll scraping; soundtrack is optional and local-only (no network).

import SwiftUI
import Combine
import AVKit
import PhotosUI
import MediaPlayer   // Used only for on-device music picker (optional, guarded by availability/entitlement)
import UIKit

// MARK: - DI seams (must match your EditorPipeline)

public enum EditorExportPreset: String, CaseIterable, Sendable {
    case feed     // 1080x1080 square, h264 ~8Mbps, AAC 128k
    case story    // 1080x1920 portrait, h264 ~8Mbps, AAC 128k
    case archive  // source-sized, higher bitrate
}

public enum EditorFilter: String, CaseIterable, Sendable {
    case none, vivid, mono, film, cool, warm
}

public struct EditorTextOverlay: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var position: CGPoint // normalized 0…1 in render space
    public var fontPointSize: CGFloat
    public var color: Color
    public init(id: UUID = UUID(), text: String, position: CGPoint, fontPointSize: CGFloat, color: Color) {
        self.id = id; self.text = text; self.position = position; self.fontPointSize = fontPointSize; self.color = color
    }
}

public protocol EditorPipelining: AnyObject {
    // Load & timeline
    func load(asset: AVAsset) async throws
    func setTrim(start: CMTime, end: CMTime) async
    func setPlaybackRate(_ rate: Float) async                       // 0.5…2.0 (applies time mapping)
    func setFilter(_ filter: EditorFilter) async
    func setTextOverlays(_ overlays: [EditorTextOverlay]) async
    func setSoundtrack(url: URL?) async                              // nil removes
    func enableLegibleCaptions(_ on: Bool) async

    // Readouts
    var durationPublisher: AnyPublisher<CMTimeRange, Never> { get }  // total range after trims/time map
    var previewPlayer: AVPlayer? { get }                             // owned by pipeline for real-time preview
    var hasLegibleTracks: Bool { get }

    // Export
    func export(preset: EditorExportPreset) async throws -> URL
    var exportProgressPublisher: AnyPublisher<Double, Never> { get } // 0…1
    func cancelExport()                                              // best-effort cancel
}

// MARK: - ViewModel

@MainActor
public final class EditorViewModel: ObservableObject {
    @Published public private(set) var timeline: CMTimeRange = .zero
    @Published public private(set) var isExporting = false
    @Published public private(set) var exportProgress: Double = 0
    @Published public private(set) var currentPreset: EditorExportPreset = .feed
    @Published public private(set) var currentFilter: EditorFilter = .none
    @Published public private(set) var overlays: [EditorTextOverlay] = []
    @Published public private(set) var captionsEnabled = true
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?
    @Published public var soundtrackName: String?

    public let player: AVPlayer

    private let pipeline: EditorPipelining
    private let asset: AVAsset
    private var cancellables = Set<AnyCancellable>()

    public init(asset: AVAsset, pipeline: EditorPipelining) {
        self.asset = asset
        self.pipeline = pipeline
        self.player = pipeline.previewPlayer ?? AVPlayer()
        bind()
    }

    private func bind() {
        pipeline.durationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.timeline = $0 }
            .store(in: &cancellables)

        pipeline.exportProgressPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.exportProgress = $0 }
            .store(in: &cancellables)
    }

    public func onAppear() {
        Task {
            do {
                try await pipeline.load(asset: asset)
                try? await Task.sleep(nanoseconds: 50_000_000)
                player.play() // kick preview; muted by default via pipeline
            } catch {
                errorMessage = NSLocalizedString("Couldn’t load that clip.", comment: "load fail")
            }
        }
    }

    public func setTrim(start: Double, end: Double) {
        let s = CMTime(seconds: start, preferredTimescale: 600)
        let e = CMTime(seconds: end, preferredTimescale: 600)
        Task { await pipeline.setTrim(start: s, end: e) }
    }

    public func setRate(_ r: Float) {
        Task { await pipeline.setPlaybackRate(r) }
    }

    public func setFilter(_ f: EditorFilter) {
        currentFilter = f
        Task { await pipeline.setFilter(f) }
    }

    public func toggleCaptions(_ on: Bool) {
        captionsEnabled = on
        Task { await pipeline.enableLegibleCaptions(on) }
    }

    public func addOverlayCenter() {
        var o = overlays
        o.append(.init(text: NSLocalizedString("Your text", comment: "overlay default"),
                       position: CGPoint(x: 0.5, y: 0.5), fontPointSize: 48, color: .white))
        overlays = o
        Task { await pipeline.setTextOverlays(o) }
    }

    public func removeOverlay(_ id: UUID) {
        overlays.removeAll { $0.id == id }
        Task { await pipeline.setTextOverlays(overlays) }
    }

    public func updateOverlay(_ m: EditorTextOverlay) {
        if let i = overlays.firstIndex(where: { $0.id == m.id }) {
            overlays[i] = m
            Task { await pipeline.setTextOverlays(overlays) }
        }
    }

    public func pickSoundtrack(url: URL?, name: String?) {
        soundtrackName = name
        Task { await pipeline.setSoundtrack(url: url) }
    }

    public func export() {
        guard !isExporting else { return }
        isExporting = true
        infoMessage = NSLocalizedString("Export started…", comment: "export start")
        Task {
            do {
                let url = try await pipeline.export(preset: currentPreset)
                isExporting = false
                infoMessage = NSLocalizedString("Export complete.", comment: "export ok")
                // Present share sheet
                await MainActor.run {
                    ExportShareSheetPresenter.shared.present(url: url)
                }
            } catch {
                isExporting = false
                errorMessage = NSLocalizedString("Export failed. Try a lower preset.", comment: "export fail")
            }
        }
    }

    public func cancelExport() {
        pipeline.cancelExport()
        isExporting = false
        infoMessage = NSLocalizedString("Export canceled.", comment: "export cancel")
    }
}

// MARK: - View

public struct EditorView: View {
    @ObservedObject private var vm: EditorViewModel

    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 1
    @State private var playbackRate: Float = 1.0
    @State private var showMusicPicker = false

    public init(viewModel: EditorViewModel) {
        self.vm = viewModel
    }

    public var body: some View {
        VStack(spacing: 12) {
            preview
            controlsBar
            trimBar
            overlayEditor
            exportBar
        }
        .padding(12)
        .navigationTitle(Text(NSLocalizedString("Editor", comment: "nav")))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.onAppear() }
        .sheet(isPresented: $showMusicPicker) {
            SoundtrackPicker { url, title in
                vm.pickSoundtrack(url: url, name: title)
            }
        }
        .overlay(progressOverlay)
        .overlay(toastOverlay)
        .accessibilityElement(children: .contain)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            VideoPlayer(player: vm.player)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .accessibilityLabel(Text(NSLocalizedString("Video preview", comment: "preview")))

            HStack(spacing: 8) {
                Image(systemName: "captions.bubble")
                Text(vm.captionsEnabled ? NSLocalizedString("Captions On", comment: "") :
                                          NSLocalizedString("Captions Off", comment: ""))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(8)
            .background(Color.black.opacity(0.45), in: Capsule())
            .padding(10)
            .accessibilityHidden(true)
        }
    }

    // MARK: Controls (filter / speed / captions / soundtrack)

    private var controlsBar: some View {
        HStack(spacing: 8) {
            Menu {
                Picker(NSLocalizedString("Filter", comment: "filter"), selection: Binding(get: { vm.currentFilter }, set: vm.setFilter)) {
                    ForEach(EditorFilter.allCases, id: \.self) { f in
                        Text(label(for: f)).tag(f)
                    }
                }
            } label: {
                pill(icon: "camera.filters", text: label(for: vm.currentFilter))
            }
            .accessibilityLabel(Text(NSLocalizedString("Filter", comment: "")))

            Menu {
                Picker(NSLocalizedString("Speed", comment: "speed"), selection: Binding(get: { playbackRate }, set: { playbackRate = $0; vm.setRate($0) })) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Text(String(format: "%.2gx", r)).tag(Float(r))
                    }
                }
            } label: {
                pill(icon: "speedometer", text: String(format: "%.2gx", playbackRate))
            }
            .accessibilityLabel(Text(NSLocalizedString("Playback speed", comment: "")))

            Toggle(isOn: Binding(get: { vm.captionsEnabled }, set: vm.toggleCaptions)) {
                Image(systemName: vm.captionsEnabled ? "captions.bubble.fill" : "captions.bubble")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)
            .accessibilityLabel(Text(NSLocalizedString("Captions", comment: "")))

            Button {
                showMusicPicker = true
            } label: {
                pill(icon: "music.note", text: vm.soundtrackName ?? NSLocalizedString("Soundtrack", comment: "soundtrack"))
            }
            .accessibilityIdentifier("editor_soundtrack")
        }
    }

    private func label(for f: EditorFilter) -> String {
        switch f {
        case .none: return NSLocalizedString("None", comment: "")
        case .vivid: return NSLocalizedString("Vivid", comment: "")
        case .mono:  return NSLocalizedString("Mono", comment: "")
        case .film:  return NSLocalizedString("Film", comment: "")
        case .cool:  return NSLocalizedString("Cool", comment: "")
        case .warm:  return NSLocalizedString("Warm", comment: "")
        }
    }

    // MARK: Trim

    private var trimBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Trim", comment: "trim")).font(.headline)
            HStack {
                Text(timeString(from: vm.timeline.start.seconds + trimStart * vm.timeline.duration.seconds))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(timeString(from: vm.timeline.start.seconds + trimEnd * vm.timeline.duration.seconds))
                    .font(.caption).foregroundStyle(.secondary)
            }
            RangeSlider(valueStart: $trimStart, valueEnd: $trimEnd)
                .frame(height: 36)
                .onChange(of: trimStart) { _ in pushTrim() }
                .onChange(of: trimEnd) { _ in pushTrim() }
                .accessibilityIdentifier("editor_trim")
        }
        .padding(.vertical, 4)
    }

    private func pushTrim() {
        let total = vm.timeline.duration.seconds
        let start = total * trimStart
        let end = total * trimEnd
        vm.setTrim(start: start, end: end)
    }

    // MARK: Overlays editor

    private var overlayEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("Text & Stickers", comment: "overlays")).font(.headline)
                Spacer()
                Button {
                    vm.addOverlayCenter()
                } label: {
                    Label(NSLocalizedString("Add Text", comment: "add text"), systemImage: "textformat")
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("editor_add_text")
            }
            if vm.overlays.isEmpty {
                Text(NSLocalizedString("No overlays yet.", comment: "empty overlays"))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(vm.overlays) { o in
                    OverlayRow(overlay: o, onChange: vm.updateOverlay, onDelete: { vm.removeOverlay(o.id) })
                        .accessibilityIdentifier("overlay_row_\(o.id)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Export

    private var exportBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Export", comment: "export")).font(.headline)
            HStack(spacing: 8) {
                Menu {
                    Picker(NSLocalizedString("Preset", comment: "preset"), selection: Binding(get: { vm.currentPreset }, set: { vm.currentPreset = $0 })) {
                        ForEach(EditorExportPreset.allCases, id: \.self) { p in
                            Text(label(for: p)).tag(p)
                        }
                    }
                } label: {
                    pill(icon: "rectangle.compress.vertical", text: label(for: vm.currentPreset))
                }
                .accessibilityLabel(Text(NSLocalizedString("Export preset", comment: "")))

                Spacer()

                Button(action: vm.export) {
                    Label(NSLocalizedString("Export", comment: "export"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 54)
                .disabled(vm.isExporting)
                .accessibilityIdentifier("editor_export")
            }
        }
        .padding(.top, 2)
    }

    private func label(for p: EditorExportPreset) -> String {
        switch p {
        case .feed: return NSLocalizedString("Feed (1080x1080)", comment: "")
        case .story: return NSLocalizedString("Story (1080x1920)", comment: "")
        case .archive: return NSLocalizedString("Archive (Source)", comment: "")
        }
    }

    // MARK: Progress & Toasts

    @ViewBuilder
    private var progressOverlay: some View {
        if vm.isExporting {
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    ProgressView(value: vm.exportProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Button(role: .destructive, action: vm.cancelExport) {
                        Text(NSLocalizedString("Cancel", comment: "cancel"))
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("editor_cancel_export")
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut, value: vm.isExporting)
        }
    }

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

    private func pill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).imageScale(.medium)
            Text(text).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func autoDismiss(_ body: @escaping () -> Void) {
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run(body) }
    }
}

// MARK: - Trim Range slider (simple, accessible)

fileprivate struct RangeSlider: View {
    @Binding var valueStart: Double // 0…1
    @Binding var valueEnd: Double   // 0…1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                let width = geo.size.width
                let s = CGFloat(valueStart) * width
                let e = CGFloat(valueEnd) * width
                Capsule().fill(Color.accentColor.opacity(0.3))
                    .frame(width: max(0, e - s))
                    .offset(x: s)
                handle(x: s) { dx in
                    valueStart = min(max(0, Double((s + dx) / width)), valueEnd - 0.02)
                }
                handle(x: e) { dx in
                    valueEnd = max(min(1, Double((e + dx) / width)), valueStart + 0.02)
                }
            }
        }
    }

    private func handle(x: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        DraggableHandle(x: x, onDrag: onDrag)
            .accessibilityAddTraits(.isAdjustable)
            .accessibilityValue(Text(String(format: "%.0f%%", x)))
    }

    private struct DraggableHandle: View {
        @State private var lastX: CGFloat = 0
        let x: CGFloat
        let onDrag: (CGFloat) -> Void
        var body: some View {
            Circle()
                .fill(.white)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                .frame(width: 28, height: 28)
                .shadow(radius: 1)
                .position(x: x, y: 18)
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let dx = g.translation.width - lastX
                    lastX = g.translation.width
                    onDrag(dx)
                }.onEnded { _ in lastX = 0 })
                .accessibilityLabel(Text(NSLocalizedString("Trim handle", comment: "")))
        }
    }
}

// MARK: - Overlay row editor

fileprivate struct OverlayRow: View {
    @State var overlay: EditorTextOverlay
    let onChange: (EditorTextOverlay) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(NSLocalizedString("Text", comment: "text"), text: Binding(get: { overlay.text }, set: { overlay.text = $0; onChange(overlay) }))
                .textInputAutocapitalization(.sentences)
                .disableAutocorrection(false)

            HStack(spacing: 8) {
                Stepper(value: Binding(get: { overlay.fontPointSize }, set: { overlay.fontPointSize = $0; onChange(overlay) }), in: 18...120, step: 2) {
                    Text(String(format: NSLocalizedString("Size: %.0f", comment: "size"), overlay.fontPointSize))
                }
                Spacer()
                ColorPicker(NSLocalizedString("Color", comment: "color"),
                            selection: Binding(get: { overlay.color }, set: { overlay.color = $0; onChange(overlay) }))
                    .labelsHidden()
                    .frame(width: 44, height: 44)
            }

            HStack {
                Text(NSLocalizedString("Position", comment: "pos")).font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { overlay.position.x }, set: { overlay.position.x = $0; onChange(overlay) }), in: 0...1) {
                    Text("X")
                }
                Slider(value: Binding(get: { overlay.position.y }, set: { overlay.position.y = $0; onChange(overlay) }), in: 0...1) {
                    Text("Y")
                }
            }

            HStack {
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Label(NSLocalizedString("Remove", comment: "remove"), systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Soundtrack picker (local only)

fileprivate struct SoundtrackPicker: UIViewControllerRepresentable {
    let onPick: (URL?, String?) -> Void
    func makeUIViewController(context: Context) -> some UIViewController {
        if #available(iOS 15.0, *) {
            // Use MPMediaPickerController for local music. This requires entitlement/user library permission in some cases.
            let picker = MPMediaPickerController(mediaTypes: .music)
            picker.allowsPickingMultipleItems = false
            picker.showsCloudItems = false
            picker.prompt = NSLocalizedString("Pick a soundtrack (local music)", comment: "")
            picker.delegate = context.coordinator
            return picker
        } else {
            return UIActivityViewController(activityItems: [], applicationActivities: nil)
        }
    }
    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let onPick: (URL?, String?) -> Void
        init(onPick: @escaping (URL?, String?) -> Void) { self.onPick = onPick }
        func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
            let item = mediaItemCollection.items.first
            // We only pass along the assetURL (DRM-free only); nil if protected.
            onPick(item?.assetURL, item?.title)
            mediaPicker.presentingViewController?.dismiss(animated: true)
        }
        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            onPick(nil, nil)
            mediaPicker.presentingViewController?.dismiss(animated: true)
        }
    }
}

// MARK: - Utilities

fileprivate func timeString(from seconds: Double) -> String {
    let s = Int(seconds.rounded())
    let m = s / 60, sec = s % 60
    return String(format: "%02d:%02d", m, sec)
}

// MARK: - Export share presenter (UIKit bridge)

fileprivate final class ExportShareSheetPresenter {
    static let shared = ExportShareSheetPresenter()
    private init() {}
    func present(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = root.view
        root.present(vc, animated: true)
    }
}
fileprivate extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first { $0.isKeyWindow } }
}

// MARK: - Convenience builder

public extension EditorView {
    static func make(assetURL: URL, pipeline: EditorPipelining) -> EditorView {
        let asset = AVURLAsset(url: assetURL)
        return EditorView(viewModel: .init(asset: asset, pipeline: pipeline))
    }
}

// MARK: - DEBUG preview (using a bundled sample)

#if DEBUG
private final class EditorPipelineFake: EditorPipelining {
    let player = AVPlayer()
    let durationS = CurrentValueSubject<CMTimeRange, Never>(CMTimeRange(start: .zero, duration: CMTime(seconds: 12, preferredTimescale: 600)))
    let progressS = CurrentValueSubject<Double, Never>(0)
    var durationPublisher: AnyPublisher<CMTimeRange, Never> { durationS.eraseToAnyPublisher() }
    var previewPlayer: AVPlayer? { player }
    var exportProgressPublisher: AnyPublisher<Double, Never> { progressS.eraseToAnyPublisher() }
    var hasLegibleTracks: Bool = true

    func load(asset: AVAsset) async throws {
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.play()
    }
    func setTrim(start: CMTime, end: CMTime) async {
        let d = durationS.value.duration.seconds
        let s = max(0, start.seconds)
        let e = min(d, end.seconds)
        durationS.send(CMTimeRange(start: .seconds(s), end: .seconds(e)))
    }
    func setPlaybackRate(_ rate: Float) async { player.rate = rate }
    func setFilter(_ filter: EditorFilter) async {}
    func setTextOverlays(_ overlays: [EditorTextOverlay]) async {}
    func setSoundtrack(url: URL?) async {}
    func enableLegibleCaptions(_ on: Bool) async {}
    func export(preset: EditorExportPreset) async throws -> URL {
        for i in 0...100 { progressS.send(Double(i)/100.0); try? await Task.sleep(nanoseconds: 15_000_000) }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("export-\(UUID().uuidString).mp4")
        try Data().write(to: tmp)
        return tmp
    }
    func cancelExport() { progressS.send(0) }
}
struct EditorView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            EditorView.make(assetURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
                            pipeline: EditorPipelineFake())
        }
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)

        NavigationView {
            EditorView.make(assetURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
                            pipeline: EditorPipelineFake())
        }
        .preferredColorScheme(.dark)
    }
}
#endif

// MARK: - Integration notes
// • Provide a concrete EditorPipeline that conforms to `EditorPipelining`. It owns AVVideoComposition/AudioMix,
//   applies trims, rate mapping, filters (CIFilter chain), text overlays (CALayer or CoreImage compositor),
//   and optional soundtrack (AVMutableComposition). It must feed `previewPlayer` for real-time preview.
// • Export: map EditorExportPreset to AVAssetExportSession presets/transform and fileType .mp4; publish progress 0…1.
// • Captions: when asset has a legible group, `enableLegibleCaptions(true)` should select default track in preview and burn-in during export if desired.
// • Info.plist: NSPhotoLibraryAddUsageDescription if saving to Photos; otherwise we share the file URL only.
// • Performance: keep real-time preview under 8%/hr budget; prefer hardware codecs, prebuild video composition.
// • UITest IDs: "editor_trim", "editor_soundtrack", "editor_export", "editor_cancel_export".

// MARK: - Test plan (unit / UI)
// Unit:
// • Trim mapping: setTrim(2.0, 8.0) updates durationPublisher to 6s; enforcing min gap 0.02 in RangeSlider.
// • Filters: setFilter() idempotent; nil → .none. Verify pipeline composes CIFilter chain without crashing.
// • Overlays: add/update/remove calls setTextOverlays with expected models.
// • Export: progressPublisher emits monotonically 0…1; cancelExport resets state; returned URL exists.
// UI:
// • AX sizes render without clipping; buttons ≥44pt. RangeSlider handles are draggable.
// • Captions toggle changes preview rendering when legible tracks present.
// • Soundtrack picker denies protected tracks (assetURL nil) gracefully; name label updates or clears.


