// Features/UX/RideMode.swift
import Foundation

public enum RideMode: String, CaseIterable, Identifiable {
    case smoothest
    case chillFewCrossings
    case fastMildRoughness
    case trickSpotCrawl
    case nightSafe

    public var id: String { rawValue }

    /// Small bias applied to the route scoring (positive favors higher smoothness).
    var bias: Double {
        switch self {
        case .smoothest: return 0.10
        case .chillFewCrossings: return 0.05
        case .fastMildRoughness: return -0.05
        case .trickSpotCrawl: return -0.10
        case .nightSafe: return 0.08
        }
    }

    public var label: String {
        switch self {
        case .smoothest: return "Smoothest"
        case .chillFewCrossings: return "Chill"
        case .fastMildRoughness: return "Fast"
        case .trickSpotCrawl: return "Trick Crawl"
        case .nightSafe: return "Night Safe"
        }
    }
}
