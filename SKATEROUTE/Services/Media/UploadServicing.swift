// Services/Media/UploadServicing.swift
// Lightweight protocol for avatar/media uploads that can be sanitized before sending to the network.

import Foundation

public protocol UploadServicing: AnyObject {
    func uploadAvatarSanitized(data: Data, key: String, contentType: String) async throws -> URL
}
