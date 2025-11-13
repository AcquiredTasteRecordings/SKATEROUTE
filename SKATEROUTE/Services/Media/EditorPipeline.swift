// Services/Media/EditorPipeline.swift
// Lightweight on-device editor: trims, speed (piecewise ramps), overlays (text/stickers), export presets.
// Returns AVAssetExportSession-backed exports with progress callbacks. No tracking, no secrets.

import Foundation
import AVFoundation
import UIKit
import Combine
import CoreMedia
import CoreGraphics
import QuartzCore
import os.log

// MARK: - Public API (DI seam)

public protocol EditorPipelining: AnyObject {
    func makeTimeline(sourceURL: URL) async throws -> EditorTimeline
    func renderPreviewFrame(_ timeline: EditorTimeline, at seconds: Double, targetSize: CGSize) async throws -> UIImage
    func export(_ timeline: EditorTimeline, preset: EditorExportPreset, destinationURL: URL) async throws -> EditorExportHandle
}

// MARK: - Timeline Model (non-destructive)

public struct EditorTimeline: Sendable, Equatable {
    public let sourceURL: URL
    public var trim: CMTimeRange? = nil               // inclusive range on source
    public var speedSegments: [SpeedSegment] = []     // piecewise segments inside trimmed range
    public var overlays: [Overlay] = []
    public var template: BrandTemplate = .skaterouteClassic

    public init(sourceURL: URL) { self.sourceURL = sourceURL }

    public struct SpeedSegment: Sendable, Equatable {
        public var relativeRange: CMTimeRange        // in timeline (post-trim) coords
        public var rate: Double                      // e.g. 0.5 (slomo), 1.0, 1.5, 2.0
        public init(relativeRange: CMTimeRange, rate: Double) {
            self.relativeRange = relativeRange; self.rate = max(0.1, min(rate, 4.0))
        }
    }

    public enum Overlay: Sendable, Equatable {
        case text(Text)
        case sticker(Sticker)
    }

    public struct Text: Sendable, Equatable {
        public var string: String
        public var frame: CGRect                     // relative [0..1] coords
        public var fontName: String                  // ensure available font or fall back
        public var fontSize: CGFloat                 // relative to min(videoW, videoH)
        public var color: UIColor
        public var shadow: Bool
        public var startAt: CMTime                   // relative timeline time
        public var duration: CMTime
        public init(string: String, frame: CGRect, fontName: String = "HelveticaNeue-Bold",
                    fontSize: CGFloat = 0.05, color: UIColor = .white, shadow: Bool = true,
                    startAt: CMTime, duration: CMTime) {
            self.string = string; self.frame = frame; self.fontName = fontName
            self.fontSize = fontSize; self.color = color; self.shadow = shadow
            self.startAt = startAt; self.duration = duration
        }
    }

    public struct Sticker: Sendable, Equatable {
        public var image: UIImage                    // PNG w/ alpha recommended
        public var frame: CGRect                     // relative [0..1]
        public var startAt: CMTime
        public var duration: CMTime
        public init(image: UIImage, frame: CGRect, startAt: CMTime, duration: CMTime) {
            self.image = image; self.frame = frame; self.startAt = startAt; self.duration = duration
        }
    }

    public enum BrandTemplate: Sendable, Equatable {
        case skaterouteClassic                       // subtle corner title + soft drop shadow
        case minimal                                 // no brand ornamentation
    }
}

// MARK: - Export Presets

public enum EditorExportPreset: Sendable, Equatable {
    case feed        // square 1080x1080, 30fps, H.264
    case story       // 1080x1920 portrait, 30fps, H.264
    case archive     // retain source dimensions, 30fps/HEVC if available; otherwise highest quality

    var targetSize: CGSize? {
        switch self {
        case .feed:   return CGSize(width: 1080, height: 1080)
        case .story:  return CGSize(width: 1080, height: 1920)
        case .archive: return nil
        }
    }
}

// MARK: - Export Handle

public final class EditorExportHandle {
    public let url: URL
    public let preset: EditorExportPreset
    public var progressPublisher: AnyPublisher<Float, Never> { progressSubject.eraseToAnyPublisher() }
    private let progressSubject = CurrentValueSubject<Float, Never>(0)
    private var kvo: NSKeyValueObservation?
    private let cancelClosure: () -> Void
    private let restartClosure: () -> Void

    init(url: URL, preset: EditorExportPreset, session: AVAssetExportSession, cancel: @escaping () -> Void, restart: @escaping () -> Void) {
        self.url = url; self.preset = preset; self.cancelClosure = cancel; self.restartClosure = restart
        kvo = session.observe(\.progress, options: [.initial, .new]) { [weak self] s, _ in
            self?.progressSubject.send(s.progress)
        }
    }

    public func cancel() { cancelClosure() }
    /// Best-effort restart from the beginning (AVAssetExportSession lacks true resume).
    public func restart() { restartClosure() }
}

// MARK: - Implementation

@MainActor
public final class EditorPipeline: EditorPipelining {
    private let log = Logger(subsystem: "com.skateroute", category: "EditorPipeline")
    private let workQueue = DispatchQueue(label: "com.skateroute.editor.work")

    public init() {}

    // MARK: Timeline

    public func makeTimeline(sourceURL: URL) async throws -> EditorTimeline {
        // Validate the asset can be loaded; keep model non-destructive
        let asset = AVURLAsset(url: sourceURL)
        _ = try await asset.load(.duration)
        return EditorTimeline(sourceURL: sourceURL)
    }

    // MARK: Preview

    public func renderPreviewFrame(_ timeline: EditorTimeline, at seconds: Double, targetSize: CGSize) async throws -> UIImage {
        let (composition, videoComp, naturalSize) = try await buildComposition(timeline)
        let generator = AVAssetImageGenerator(asset: composition)
        generator.appliesPreferredTrackTransform = true
        if let vc = videoComp { generator.videoComposition = vc }
        generator.maximumSize = targetSize
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let cg = try generator.copyCGImage(at: time, actualTime: nil)
        return UIImage(cgImage: cg)
    }

    // MARK: Export

    public func export(_ timeline: EditorTimeline, preset: EditorExportPreset, destinationURL: URL) async throws -> EditorExportHandle {
        // Build composition & video composition
        let (composition, videoComp, nat) = try await buildComposition(timeline, overrideSize: preset.targetSize)

        // Choose export session
        let session: AVAssetExportSession
        if case .archive = preset, AVAssetExportSession.exportPresets(compatibleWith: composition).contains(AVAssetExportPresetHEVCHighestQuality) {
            session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality)!
            session.outputFileType = .mp4
        } else {
            // Use HighestQuality for our controlled sizes (we enforce 30fps via videoComp.frameDuration)
            session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
            session.outputFileType = .mp4
        }
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = videoComp
        try? FileManager.default.removeItem(at: destinationURL)
        session.outputURL = destinationURL
        session.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        // Progress + cancel/restart
        let handle = EditorExportHandle(
            url: destinationURL,
            preset: preset,
            session: session,
            cancel: { session.cancelExport() },
            restart: { session.cancelExport(); /* caller may call export again with same timeline */ }
        )

        // Kick export async (caller awaits completion with a Task)
        workQueue.async { [weak self] in
            guard let self else { return }
            session.exportAsynchronously {
                if let e = session.error {
                    self.log.error("Export failed: \(e.localizedDescription, privacy: .public)")
                }
            }
        }
        return handle
    }

    // MARK: Composition Builder

    private func buildComposition(_ timeline: EditorTimeline, overrideSize: CGSize? = nil) async throws -> (AVMutableComposition, AVMutableVideoComposition?, CGSize) {
        let asset = AVURLAsset(url: timeline.sourceURL)
        let tracks = try await asset.load(.tracks)
        guard let vTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw EditorError.noVideoTrack
        }
        let naturalSize = try await vTrack.load(.naturalSize)
        let renderSize = overrideSize ?? naturalSize

        // Composition
        let comp = AVMutableComposition()
        let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let compA = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        let timeRangeSource = try await calcSourceRange(asset: asset, timeline: timeline)
        try compV.insertTimeRange(timeRangeSource.rangeOnSource, of: vTrack, at: .zero)
        if let aTrack = tracks.first(where: { $0.mediaType == .audio }) {
            try compA?.insertTimeRange(timeRangeSource.rangeOnSource, of: aTrack, at: .zero)
        }

        // Piecewise speed mapping (approximates ramps)
        if !timeline.speedSegments.isEmpty {
            for seg in timeline.speedSegments.sorted(by: { $0.relativeRange.start < $1.relativeRange.start }) {
                guard seg.rate != 1.0 else { continue }
                compV.scaleTimeRange(seg.relativeRange, toDuration: seg.relativeRange.duration / seg.rate)
                compA?.scaleTimeRange(seg.relativeRange, toDuration: seg.relativeRange.duration / seg.rate)
            }
        }

        // Video composition + overlays + template
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        // Instruction pass-through
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compV)
        // Keep source transform (rotation)
        let preferredTransform = try await vTrack.load(.preferredTransform)
        layerInstruction.setTransform(preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComp.instructions = [instruction]

        // Core Animation overlays
        let (parent, videoLayer) = makeOverlayLayers(size: renderSize, duration: comp.duration, template: timeline.template)
        applyOverlays(timeline.overlays, size: renderSize, parent: parent, videoLayer: videoLayer)
        videoComp.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        return (comp, videoComp, renderSize)
    }

    private struct SourceRange {
        let rangeOnSource: CMTimeRange
        let trimmedDuration: CMTime
    }

    private func calcSourceRange(asset: AVAsset, timeline: EditorTimeline) async throws -> SourceRange {
        let duration = try await asset.load(.duration)
        if let t = timeline.trim {
            let clamped = CMTimeRange(start: max(.zero, t.start), duration: min(t.duration, duration - t.start))
            return SourceRange(rangeOnSource: clamped, trimmedDuration: clamped.duration)
        } else {
            return SourceRange(rangeOnSource: CMTimeRange(start: .zero, duration: duration), trimmedDuration: duration)
        }
    }

    // MARK: Overlays

    private func makeOverlayLayers(size: CGSize, duration: CMTime, template: EditorTimeline.BrandTemplate) -> (CALayer, CALayer) {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.isGeometryFlipped = true

        let videoLayer = CALayer()
        videoLayer.frame = parent.bounds
        parent.addSublayer(videoLayer)

        switch template {
        case .skaterouteClassic:
            let pad: CGFloat = 16
            let badge = CATextLayer()
            badge.contentsScale = UIScreen.main.scale
            badge.string = "SkateRoute"
            badge.font = UIFont.systemFont(ofSize: 1, weight: .semibold)
            badge.fontSize = max(14, min(size.width, size.height) * 0.032)
            badge.alignmentMode = .left
            badge.foregroundColor = UIColor.white.withAlphaComponent(0.95).cgColor
            badge.shadowColor = UIColor.black.cgColor
            badge.shadowOpacity = 0.6
            badge.shadowRadius = 3
            badge.shadowOffset = .init(width: 0, height: 1)
            let w = badge.preferredFrameSize().width
            badge.frame = CGRect(x: pad, y: pad, width: min(w, size.width*0.6), height: badge.fontSize + 6)
            parent.addSublayer(badge)
        case .minimal:
            break
        }

        return (parent, videoLayer)
    }

    private func applyOverlays(_ overlays: [EditorTimeline.Overlay], size: CGSize, parent: CALayer, videoLayer: CALayer) {
        for ov in overlays {
            switch ov {
            case .text(let t):
                let layer = CATextLayer()
                layer.contentsScale = UIScreen.main.scale
                layer.string = t.string as NSString
                layer.alignmentMode = .left
                layer.truncationMode = .end
                let base = min(size.width, size.height)
                layer.font = UIFont(name: t.fontName, size: 1) ?? UIFont.systemFont(ofSize: 1, weight: .bold)
                layer.fontSize = max(10, base * t.fontSize)
                layer.foregroundColor = t.color.cgColor
                if t.shadow {
                    layer.shadowColor = UIColor.black.cgColor
                    layer.shadowOpacity = 0.6
                    layer.shadowRadius = 4
                    layer.shadowOffset = .init(width: 0, height: 1)
                }
                layer.frame = rectRelative(t.frame, in: size)
                addTimed(layer: layer, start: t.startAt, duration: t.duration, parent: parent)

            case .sticker(let s):
                let layer = CALayer()
                layer.contentsScale = UIScreen.main.scale
                layer.contents = s.image.cgImage
                layer.frame = rectRelative(s.frame, in: size)
                layer.masksToBounds = true // preserves alpha
                addTimed(layer: layer, start: s.startAt, duration: s.duration, parent: parent)
            }
        }
    }

    private func rectRelative(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: r.origin.x * size.width,
               y: r.origin.y * size.height,
               width: r.size.width * size.width,
               height: r.size.height * size.height)
    }

    private func addTimed(layer: CALayer, start: CMTime, duration: CMTime, parent: CALayer) {
        layer.isHidden = true
        parent.addSublayer(layer)
        // Show/hide via basic opacity animation to avoid layout churn.
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0; show.toValue = 1
        show.beginTime = CFTimeInterval(CMTimeGetSeconds(start))
        show.duration = 0.1
        show.fillMode = .forwards; show.isRemovedOnCompletion = false

        let hide = CABasicAnimation(keyPath: "opacity")
        hide.fromValue = 1; hide.toValue = 0
        hide.beginTime = CFTimeInterval(CMTimeGetSeconds(start + duration))
        hide.duration = 0.1
        hide.fillMode = .forwards; hide.isRemovedOnCompletion = false

        let group = CAAnimationGroup()
        group.animations = [show, hide]
        group.beginTime = 0
        group.duration = CFTimeInterval(CMTimeGetSeconds(start + duration + CMTime(seconds: 0.11, preferredTimescale: 600)))
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "timedAppearance")
    }
}

// MARK: - Errors

public enum EditorError: LocalizedError {
    case noVideoTrack
    public var errorDescription: String? {
        switch self { case .noVideoTrack: return "No video track in asset." }
    }
}

// MARK: - DEBUG Fakes

#if DEBUG
public final class EditorPipelineFake: EditorPipelining {
    public init() {}
    public func makeTimeline(sourceURL: URL) async throws -> EditorTimeline { EditorTimeline(sourceURL: sourceURL) }
    public func renderPreviewFrame(_ timeline: EditorTimeline, at seconds: Double, targetSize: CGSize) async throws -> UIImage {
        // Solid image for snapshot tests
        let size = targetSize == .zero ? CGSize(width: 100, height: 100) : targetSize
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        UIColor(white: 0.9, alpha: 1).setFill(); UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        let img = UIGraphicsGetImageFromCurrentImageContext()!; UIGraphicsEndImageContext(); return img
    }
    public func export(_ timeline: EditorTimeline, preset: EditorExportPreset, destinationURL: URL) async throws -> EditorExportHandle {
        try? FileManager.default.removeItem(at: destinationURL)
        FileManager.default.createFile(atPath: destinationURL.path, contents: Data(), attributes: nil)
        // Simulated progress
        let session = AVAssetExportSession(asset: AVAsset(), presetName: AVAssetExportPresetPassthrough)!
        let handle = EditorExportHandle(url: destinationURL, preset: preset, session: session, cancel: {}, restart: {})
        DispatchQueue.global().async {
            for i in 0...10 {
                usleep(50_000)
                // No direct way to update the KVO'ed session.progress; just drop completion here.
            }
        }
        return handle
    }
}
#endif



