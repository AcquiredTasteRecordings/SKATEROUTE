// Services/MatcherTypes.swift
import CoreLocation

/// Shared match sample used by Matcher and RideRecorder
public struct MatchSample {
    public let location: CLLocation
    public let roughnessRMS: Double

    public init(location: CLLocation, roughnessRMS: Double) {
        self.location = location
        self.roughnessRMS = roughnessRMS
    }
}
