// Features/Map/SmoothOverlayRenderer.swift
import Foundation
import MapKit
import UIKit

public final class ColoredPolyline: MKPolyline {
    public var color: UIColor = .systemBlue
    public var lineDash: [NSNumber]? = nil
    public var alpha: CGFloat = 1.0 // Alpha to indicate segment freshness (1.0 = newest, 0.0 = oldest)
    public var nextColor: UIColor? = nil // For gradient transition to next segment color
}

public enum SmoothOverlayBuilder {
    /// Builds colored polylines per step. `colors[i]` maps to `route.steps[i]`.
    /// Adds alpha fading and nextColor for gradient transitions.
    public static func build(route: MKRoute,
                                contexts: [StepContext],
                                colorProvider: (StepContext) -> UIColor,
                                brakingMask: [Bool]) -> [ColoredPolyline] {
        let steps = route.steps
        let contextLookup = Dictionary(uniqueKeysWithValues: contexts.map { ($0.stepIndex, $0) })
        var results: [ColoredPolyline] = []
        let count = steps.count
        for i in 0..<count {
            let step = steps[i]
            guard step.distance > 0 else { continue }
            let coords = step.polyline.coordinates()
            guard coords.count >= 2 else { continue }
            let seg = ColoredPolyline(coordinates: coords, count: coords.count)
            guard let context = contextLookup[i] else { continue }
            let currentColor = colorProvider(context)
            seg.color = currentColor
            
            // Assign nextColor for gradient transition if possible
            if let next = contextLookup[i + 1] {
                seg.nextColor = colorProvider(next)
            }
            
            // Alpha fade based on segment index to indicate freshness (newer segments more opaque)
            // Older segments become more transparent linearly
            seg.alpha = 1.0 - (CGFloat(i) / CGFloat(max(count - 1, 1))) * 0.7 // fade max to 0.3 alpha
            
            // Apply braking mask with dashed pattern
            if i < brakingMask.count, brakingMask[i] == true || context.brakingZone {
                seg.lineDash = [6, 8] // red dashes for braking
            }
            results.append(seg)
        }
        return results
    }
}

public final class ColoredPolylineRenderer: MKPolylineRenderer {
    /// Override to apply adaptive line width, alpha fading, gradient color, and high-DPI support.
    public override func applyStrokeProperties(to context: CGContext, atZoomScale zoomScale: MKZoomScale) {
        super.applyStrokeProperties(to: context, atZoomScale: zoomScale)
        
        guard let cp = polyline as? ColoredPolyline else { return }
        
        // Adaptive line width based on zoom scale for better detail at different zoom levels
        // Base line width is 6 points at zoomScale 1.0, scales inversely with zoomScale (higher zoom -> thinner lines)
        let baseLineWidth: CGFloat = 6.0
        let adjustedLineWidth = max(baseLineWidth / zoomScale, 1.5) // minimum line width 1.5 for visibility
        lineWidth = adjustedLineWidth
        
        lineJoin = .round
        lineCap = .round
        
        // Prepare stroke color with alpha for segment freshness
        let strokeColorWithAlpha = cp.color.withAlphaComponent(cp.alpha)
        
        // If nextColor exists, create a gradient stroke between cp.color and nextColor
        if let nextColor = cp.nextColor {
            // Create CGGradient for smooth color transition
            let colors = [cp.color.withAlphaComponent(cp.alpha).cgColor,
                          nextColor.withAlphaComponent(cp.alpha).cgColor] as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0,1]) else {
                strokeColor = strokeColorWithAlpha
                return
            }

            // Get the path of the polyline to stroke with gradient
            guard let path = self.path else {
                strokeColor = strokeColorWithAlpha
                return
            }
            context.saveGState()
            context.addPath(path)
            context.setLineWidth(lineWidth)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            if let dash = cp.lineDash {
                context.setLineDash(phase: 0, lengths: dash.map { CGFloat(truncating: $0) })
            }
            context.replacePathWithStrokedPath()
            context.clip()

            // Gradient direction along the polyline bounding box from start to end
            let boundingBox = path.boundingBox
            let startPoint = CGPoint(x: boundingBox.minX, y: boundingBox.minY)
            let endPoint = CGPoint(x: boundingBox.maxX, y: boundingBox.maxY)

            context.drawLinearGradient(gradient, start: startPoint, end: endPoint, options: [])
            context.restoreGState()

            // Do not set strokeColor because gradient is drawn manually
            return
        } else {
            // No gradient: use solid stroke color with alpha
            strokeColor = strokeColorWithAlpha
        }
        
        // Apply line dash pattern if any
        if let dash = cp.lineDash {
            lineDashPattern = dash
        } else {
            lineDashPattern = nil
        }
    }
}
