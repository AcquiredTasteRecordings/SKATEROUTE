// Services/Profile/UserProfileStore.swift
// Owns user profile state (display name, avatar, city, privacy).
// Local-first with SwiftData; optional cloud sync (Firebase/CloudKit) behind RemoteConfig.
// No PII leaves device unless user opts in. Avatar uploads are EXIF-sanitized via UploadService.

import Foundation
import SwiftData
import Combine
import UIKit

// MARK: - SwiftData model

@Model
public final class UserProfile {
    @Attribute(.unique) public var id: String            // stable user id (auth uid or device-based anon id)
    public var displayName: String
    public var city: String?
    public var avatarURL: URL?
    public var hideCity: Bool
    public var hideRoutes: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var version: Int                              // monotonic counter for optimistic concurrency
    public var lastSyncedAt: Date?                       // local bookkeeping only

    public init(id: String,
                displayName: String,
                city: String? = nil,
                avatarURL: URL? = nil,
                hideCity: Bool = false,
                hideRoutes: Bool = false,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                version: Int = 1,
                lastSyncedAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.city = city
        self.avatarURL = avatarURL
        self.hideCity = hideCity
        self.hideRoutes = hideRoutes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.lastSyncedAt = lastSyncedAt
    }
}

// MARK: - Protocol seams (DI)

public protocol RemoteConfigServing {
    var isProfileCloudSyncEnabled: Bool { get }  // toggled remotely; persisted locally
    var isProfileCloudOptIn: Bool { get }        // user’s explicit opt-in; default false
}

public protocol UploadServicing {
    /// Must strip EXIF/location before upload. Returns a stable, cacheable URL.
    func uploadAvatarSanitized(data: Data, key: String, contentType: String) async throws -> URL
}

public struct CloudProfile: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let city: String?
    public let avatarURL: URL?
    public let hideCity: Bool
    public let hideRoutes: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let version: Int
    public let serverTimestamp: Date // authoritative server write time
}

public protocol CloudProfileSyncing {
    func fetch(userId: String) async throws -> CloudProfile?
    func upsert(_ profile: CloudProfile) async throws -> CloudProfile
    func delete(userId: String) async throws
}

// MARK: - Store

@MainActor
public final class UserProfileStore: ObservableObject {

    public enum State: Equatable {
        case idle
        case loading
        case ready
        case error(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var profile: UserProfile?

    public var privacyFlags: (hideCity: Bool, hideRoutes: Bool) {
        (profile?.hideCity ?? false, profile?.hideRoutes ?? false)
    }

    private let modelContext: ModelContext
    private let remoteConfig: RemoteConfigServing
    private let cloud: CloudProfileSyncing?
    private let uploader: UploadServicing
    private var cancellables = Set<AnyCancellable>()

    public init(modelContext: ModelContext,
                remoteConfig: RemoteConfigServing,
                uploader: UploadServicing,
                cloud: CloudProfileSyncing? = nil) {
        self.modelContext = modelContext
        self.remoteConfig = remoteConfig
        self.uploader = uploader
        self.cloud = cloud
    }

    // MARK: - Bootstrap / Load

    public func load(userId: String) async {
        state = .loading
        // Load local first
        let local = try? fetchLocal(userId: userId)
        self.profile = local

        // Optionally sync cloud (if enabled AND opted in)
        if remoteConfig.isProfileCloudSyncEnabled, remoteConfig.isProfileCloudOptIn, let cloud {
            do {
                let remote = try await cloud.fetch(userId: userId)
                if let merged = try mergeApplyAndPersist(local: local, remote: remote) {
                    self.profile = merged
                }
                state = .ready
            } catch {
                // Non-fatal: keep local
                state = .ready
            }
        } else {
            state = .ready
        }
    }

    // MARK: - CRUD

    @discardableResult
    public func createOrLoad(userId: String, defaultDisplayName: String) throws -> UserProfile {
        if let existing = try fetchLocal(userId: userId) {
            profile = existing
            return existing
        }
        let p = UserProfile(id: userId, displayName: defaultDisplayName)
        modelContext.insert(p)
        try modelContext.save()
        profile = p
        return p
    }

    public func update(id userId: String,
                       displayName: String? = nil,
                       city: String? = nil,
                       hideCity: Bool? = nil,
                       hideRoutes: Bool? = nil) async {
        guard var p = profile ?? (try? fetchLocal(userId: userId)) ?? nil else { return }
        var touched = false
        if let displayName, displayName != p.displayName { p.displayName = displayName; touched = true }
        if let city, city != p.city { p.city = city; touched = true }
        if let hideCity, hideCity != p.hideCity { p.hideCity = hideCity; touched = true }
        if let hideRoutes, hideRoutes != p.hideRoutes { p.hideRoutes = hideRoutes; touched = true }

        guard touched else { return }
        p.updatedAt = Date()
        p.version += 1

        do {
            try modelContext.save()
            profile = p
            // Push if cloud enabled & opted in
            try await pushIfCloudEnabled(p)
        } catch {
            state = .error("Couldn’t save profile")
        }
    }

    public func deleteProfile(id userId: String) async {
        if let p = try? fetchLocal(userId: userId) {
            modelContext.delete(p)
            try? modelContext.save()
        }
        if remoteConfig.isProfileCloudSyncEnabled, remoteConfig.isProfileCloudOptIn, let cloud {
            try? await cloud.delete(userId: userId)
        }
        profile = nil
    }

    // MARK: - Avatar

    public func setAvatar(userId: String, imageData: Data, contentType: String = "image/jpeg") async {
        guard var p = profile ?? (try? fetchLocal(userId: userId)) ?? nil else { return }
        do {
            // Uploader MUST strip EXIF before upload.
            let key = "avatars/\(userId)-\(UUID().uuidString)"
            let url = try await uploader.uploadAvatarSanitized(data: imageData, key: key, contentType: contentType)
            p.avatarURL = url
            p.updatedAt = Date()
            p.version += 1
            try modelContext.save()
            profile = p
            try await pushIfCloudEnabled(p)
        } catch {
            state = .error("Couldn’t upload avatar")
        }
    }

    // MARK: - Privacy accessors for dependent features

    public func shouldHideCity() -> Bool { profile?.hideCity ?? false }
    public func shouldHideRoutes() -> Bool { profile?.hideRoutes ?? false }

    // MARK: - Migration when cloud toggle flips ON

    public func migrateToCloudIfNeeded(userId: String) async {
        guard remoteConfig.isProfileCloudSyncEnabled,
              remoteConfig.isProfileCloudOptIn,
              let cloud else { return }
        do {
            let local = try fetchLocal(userId: userId)
            let remote = try await cloud.fetch(userId: userId)
            _ = try mergeApplyAndPersist(local: local, remote: remote) // persists whichever wins
            if let merged = profile { try await pushIfCloudEnabled(merged) }
        } catch {
            // swallow; local remains source of truth
        }
    }

    // MARK: - Internals

    private func fetchLocal(userId: String) throws -> UserProfile? {
        let descriptor = FetchDescriptor<UserProfile>(predicate: #Predicate { $0.id == userId })
        return try modelContext.fetch(descriptor).first
    }

    /// Merge policy: last-write-wins with server timestamp bias.
    /// - If remote exists and `remote.serverTimestamp` >= local.updatedAt - skew, prefer remote;
    ///   else prefer local. When both changed, field-wise resolve by latest timestamp.
    private func mergeApplyAndPersist(local: UserProfile?,
                                      remote: CloudProfile?,
                                      clockSkewTolerance: TimeInterval = 3.0) throws -> UserProfile? {
        switch (local, remote) {
        case (nil, nil):
            return nil
        case (let l?, nil):
            // keep local as-is
            profile = l
            return l
        case (nil, let r?):
            let merged = mapRemoteToLocal(r)
            modelContext.insert(merged)
            try modelContext.save()
            profile = merged
            return merged
        case (let l?, let r?):
            let biasRemote = r.serverTimestamp >= l.updatedAt.addingTimeInterval(-clockSkewTolerance)
            let winner: UserProfile
            if biasRemote {
                winner = resolveFieldwise(local: l, remote: r)
            } else {
                winner = l
            }
            try modelContext.save()
            profile = winner
            return winner
        }
    }

    private func resolveFieldwise(local l: UserProfile, remote r: CloudProfile) -> UserProfile {
        // For simplicity, when biasing remote we overwrite all fields except createdAt if local is earlier.
        l.displayName = r.displayName
        l.city = r.city
        l.avatarURL = r.avatarURL
        l.hideCity = r.hideCity
        l.hideRoutes = r.hideRoutes
        l.updatedAt = max(l.updatedAt, r.updatedAt)
        l.version = max(l.version, r.version)
        if r.createdAt < l.createdAt { l.createdAt = r.createdAt }
        l.lastSyncedAt = Date()
        return l
    }

    private func mapRemoteToLocal(_ r: CloudProfile) -> UserProfile {
        UserProfile(id: r.id,
                    displayName: r.displayName,
                    city: r.city,
                    avatarURL: r.avatarURL,
                    hideCity: r.hideCity,
                    hideRoutes: r.hideRoutes,
                    createdAt: r.createdAt,
                    updatedAt: r.updatedAt,
                    version: r.version,
                    lastSyncedAt: Date())
    }

    private func pushIfCloudEnabled(_ p: UserProfile) async throws {
        guard remoteConfig.isProfileCloudSyncEnabled, remoteConfig.isProfileCloudOptIn, let cloud else { return }
        let payload = CloudProfile(id: p.id,
                                   displayName: p.displayName,
                                   city: p.city,
                                   avatarURL: p.avatarURL,
                                   hideCity: p.hideCity,
                                   hideRoutes: p.hideRoutes,
                                   createdAt: p.createdAt,
                                   updatedAt: p.updatedAt,
                                   version: p.version,
                                   serverTimestamp: Date()) // server will overwrite this when accepted
        let confirmed = try await cloud.upsert(payload)
        // Re-apply authoritative fields (updatedAt/version) if server mutated them.
        _ = try mergeApplyAndPersist(local: p, remote: confirmed)
    }
}

// MARK: - Test Fakes (DEBUG)

#if DEBUG
public final class RemoteConfigFake: RemoteConfigServing {
    public var isProfileCloudSyncEnabled: Bool
    public var isProfileCloudOptIn: Bool
    public init(enabled: Bool = false, optIn: Bool = false) {
        self.isProfileCloudSyncEnabled = enabled
        self.isProfileCloudOptIn = optIn
    }
}

public final class UploadServiceFake: UploadServicing {
    public init() {}
    public func uploadAvatarSanitized(data: Data, key: String, contentType: String) async throws -> URL {
        // Pretend to strip EXIF and return a file URL.
        return URL(string: "https://cdn.skateroute.app/\(key).jpg")!
    }
}

public final class CloudSyncFake: CloudProfileSyncing {
    private var store: [String: CloudProfile] = [:]
    public init() {}
    public func fetch(userId: String) async throws -> CloudProfile? { store[userId] }
    public func upsert(_ profile: CloudProfile) async throws -> CloudProfile {
        let confirmed = CloudProfile(id: profile.id,
                                     displayName: profile.displayName,
                                     city: profile.city,
                                     avatarURL: profile.avatarURL,
                                     hideCity: profile.hideCity,
                                     hideRoutes: profile.hideRoutes,
                                     createdAt: profile.createdAt,
                                     updatedAt: Date(), // server now
                                     version: max(profile.version, (store[profile.id]?.version ?? 0) + 1),
                                     serverTimestamp: Date())
        store[profile.id] = confirmed
        return confirmed
    }
    public func delete(userId: String) async throws { store.removeValue(forKey: userId) }
}
#endif


