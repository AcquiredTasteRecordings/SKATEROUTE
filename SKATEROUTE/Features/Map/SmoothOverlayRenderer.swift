// Features/Map/SmoothOverlayRenderer.swift
// High-quality gradient polyline renderer with smoothing and casing.
// Use this in MKMapViewDelegate instead of MKPolylineRenderer for nicer visuals.

import MapKit
import UIKit
import CoreGraphics

/// A renderer that draws a smoothed polyline with an optional gradient stroke and outer "casing".
/// Works with any MKPolyline; gradient is along path length (start → end).
public final class SmoothOverlayRenderer: MKOverlayPathRenderer {

    // MARK: - Public knobs

    /// Base stroke color when no gradient is provided.
    public var strokeColor: UIColor = .systemBlue

    /// Optional gradient colors (start → end). If nil or < 2, falls back to `strokeColor`.
    public var gradientColors: [UIColor]? = nil

    /// Outer casing (outline) color. Set to nil to disable.
    public var casingColor: UIColor? = UIColor.white.withAlphaComponent(0.8)

    /// Stroke width in points at 1.0 zoom scale (MapKit will scale with zoom).
    public var lineWidthPoints: CGFloat = 6

    /// Extra width for casing over the inner stroke (points at 1.0 zoom).
    public var casingExtraWidthPoints: CGFloat = 2

    /// Smoothing parameter for Catmull–Rom (0 = off, 0.4–0.6 = pleasant, >0.8 can overshoot).
    public var smoothing: CGFloat = 0.5

    // MARK: - Internals

    private let polyline: MKPolyline
    private var cachedZoomScale: MKZoomScale?
    private var cachedPath: CGPath?

    // MARK: - Init

    public init(polyline: MKPolyline,
                colors: [UIColor]? = nil,
                strokeWidth: CGFloat = 6,
                casing: UIColor? = UIColor.white.withAlphaComponent(0.8),
                casingExtra: CGFloat = 2,
                smoothing: CGFloat = 0.5) {
        self.polyline = polyline
        self.gradientColors = colors
        self.lineWidthPoints = strokeWidth
        self.casingColor = casing
        self.casingExtraWidthPoints = casingExtra
        self.smoothing = smoothing
        super.init(overlay: polyline)
        self.alpha = 1.0
        self.strokeColor = colors?.first ?? strokeColor
        self.lineJoin = .round
        self.lineCap = .round
    }

    // MARK: - Lifecycle

    public override func applyStrokeProperties(to context: CGContext, atZoomScale zoomScale: MKZoomScale) {
        // We override draw(_:zoomScale:in:) instead; let super apply defaults to match our properties.
        super.applyStrokeProperties(to: context, atZoomScale: zoomScale)
    }

    public override func createPath() {
        // Build and cache path for the current zoomScale (since smoothing happens in screen space).
        guard let points = screenPoints(for: polyline) else {
            path = nil
            return
        }
        let smoothed = smoothing > 0 ? catmullRomPath(points: points, alpha: smoothing) : polylinePath(points: points)
        path = smoothed
        cachedPath = smoothed
    }

    public override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        // Rebuild path when zoom changes significantly; we cache by zoomScale to avoid pixel wobble.
        if cachedZoomScale == nil || abs((cachedZoomScale ?? zoomScale) - zoomScale) / max(zoomScale, 1) > 0.05 {
            cachedZoomScale = zoomScale
            setNeedsDisplay()
            createPath()
        } else if path == nil {
            createPath()
        }

        guard let path else { return }

        context.saveGState()

        // Compute widths in screen space
        let strokeW = max(1, lineWidthPoints / zoomScale)
        let casingW = max(0, (lineWidthPoints + casingExtraWidthPoints) / zoomScale)

        // Draw casing first (beneath)
        if let casingColor {
            context.addPath(path)
            context.setLineWidth(casingW)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.setStrokeColor(casingColor.cgColor)
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.strokePath()
        }

        // Draw gradient stroke (or solid color) on top
        if let colors = gradientColors, colors.count >= 2, let grad = cgGradient(from: colors) {
            // Create a stroked-path outline to use as a clip, then fill gradient.
            guard let stroked = path.copy(strokingWithWidth: strokeW,
                                          lineCap: .round,
                                          lineJoin: .round,
                                          miterLimit: 2) else {
                context.restoreGState()
                return
            }
            context.addPath(stroked)
            context.clip()

            let bounds = stroked.boundingBoxOfPath
            // Gradient direction roughly along path: start at minX/minY → maxX/maxY.
            let start = CGPoint(x: bounds.minX, y: bounds.minY)
            let end   = CGPoint(x: bounds.maxX, y: bounds.maxY)
            context.drawLinearGradient(grad, start: start, end: end, options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
        } else {
            // Solid stroke
            context.addPath(path)
            context.setLineWidth(strokeW)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.setStrokeColor(strokeColor.cgColor)
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.strokePath()
        }

        context.restoreGState()
    }

    // MARK: - Utilities (path building)

    private func screenPoints(for polyline: MKPolyline) -> [CGPoint]? {
        var buffer = [MKMapPoint](repeating: .init(), count: polyline.pointCount)
        guard polyline.pointCount >= 2 else { return nil }
        polyline.getPoints(&buffer, range: NSRange(location: 0, length: polyline.pointCount))
        return buffer.map { point(for: $0) }
    }

    private func polylinePath(points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        if let first = points.first {
            p.move(to: first)
            for i in 1..<points.count { p.addLine(to: points[i]) }
        }
        return p
    }

    /// Catmull–Rom spline (centripetal) through the points — low overshoot, nice corners.
    private func catmullRomPath(points: [CGPoint], alpha: CGFloat) -> CGPath {
        guard points.count > 2 else { return polylinePath(points: points) }
        let path = CGMutablePath()
        let pts = points

        // Insert phantom endpoints for end-conditions
        var extended: [CGPoint] = []
        extended.reserveCapacity(pts.count + 2)
        let firstDelta = CGPoint(x: pts[1].x - pts[0].x, y: pts[1].y - pts[0].y)
        let lastDelta  = CGPoint(x: pts[pts.count-1].x - pts[pts.count-2].x, y: pts[pts.count-1].y - pts[pts.count-2].y)
        extended.append(CGPoint(x: pts[0].x - firstDelta.x, y: pts[0].y - firstDelta.y))
        extended.append(contentsOf: pts)
        extended.append(CGPoint(x: pts.last!.x + lastDelta.x, y: pts.last!.y + lastDelta.y))

        path.move(to: pts[0])

        for i in 0..<(extended.count - 3) {
            let p0 = extended[i]
            let p1 = extended[i + 1]
            let p2 = extended[i + 2]
            let p3 = extended[i + 3]

            // Parameterize with centripetal Catmull–Rom to avoid loops/overshoot
            func tj(_ ti: CGFloat, _ pi: CGPoint, _ pj: CGPoint) -> CGFloat {
                let dx = pj.x - pi.x, dy = pj.y - pi.y
                let d = sqrt(dx*dx + dy*dy)
                return ti + pow(d, alpha)
            }
            let t0: CGFloat = 0
            let t1 = tj(t0, p0, p1)
            let t2 = tj(t1, p1, p2)
            let t3 = tj(t2, p2, p3)

            // Resample this segment with a few subdivisions for smoothness
            let segments = 6
            for j in 1...segments {
                let t = t1 + (CGFloat(j) / CGFloat(segments)) * (t2 - t1)
                let a1 = lerpCR(p0, p1, t0, t1, t)
                let a2 = lerpCR(p1, p2, t1, t2, t)
                let a3 = lerpCR(p2, p3, t2, t3, t)
                let b1 = lerpCR(a1, a2, t0, t2, t)
                let b2 = lerpCR(a2, a3, t1, t3, t)
                let c  = lerpCR(b1, b2, t1, t2, t)
                path.addLine(to: c)
            }
        }

        return path
    }

    private func lerpCR(_ p0: CGPoint, _ p1: CGPoint, _ t0: CGFloat, _ t1: CGFloat, _ t: CGFloat) -> CGPoint {
        let u = (t - t0) / (t1 - t0)
        return CGPoint(x: p0.x + u * (p1.x - p0.x),
                       y: p0.y + u * (p1.y - p0.y))
    }

    // MARK: - Gradient helper

    private func cgGradient(from colors: [UIColor]) -> CGGradient? {
        let cgColors = colors.map { $0.cgColor } as CFArray
        let locs: [CGFloat] = stride(from: 0, through: 1, by: 1.0 / CGFloat(max(1, colors.count - 1))).map { $0 }
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: locs)
    }
}

// MARK: - Convenience: delegate factory

public enum SmoothOverlayFactory {
    /// Return a SmoothOverlayRenderer for MKPolyline with optional gradient, else nil.
    public static func makeRenderer(for overlay: MKOverlay,
                                    zoomScale: MKZoomScale,
                                    defaultColor: UIColor = .systemBlue,
                                    gradient: [UIColor]? = nil,
                                    strokeWidth: CGFloat = 6,
                                    casing: UIColor? = UIColor.white.withAlphaComponent(0.8),
                                    casingExtra: CGFloat = 2,
                                    smoothing: CGFloat = 0.5) -> MKOverlayRenderer? {
        guard let pl = overlay as? MKPolyline else { return nil }
        let r = SmoothOverlayRenderer(polyline: pl,
                                      colors: gradient,
                                      strokeWidth: strokeWidth,
                                      casing: casing,
                                      casingExtra: casingExtra,
                                      smoothing: smoothing)
        r.strokeColor = defaultColor
        return r
    }
}


