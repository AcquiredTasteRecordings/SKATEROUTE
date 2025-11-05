import CoreLocation

public enum AccuracyProfile {
    case navigation, balanced, background

    public var desiredAccuracy: CLLocationAccuracy {
        switch self {
        case .navigation: return kCLLocationAccuracyBestForNavigation
        case .balanced:   return kCLLocationAccuracyNearestTenMeters
        case .background: return kCLLocationAccuracyHundredMeters
        }
    }

    public var distanceFilter: CLLocationDistance {
        switch self {
        case .navigation: return 5
        case .balanced:   return 20
        case .background: return 100
        }
    }
}
