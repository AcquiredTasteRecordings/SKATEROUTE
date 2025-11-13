//  Services/Rewards/RewardsStore.swift
//  SKATEROUTE
//

import Foundation

public enum RewardsStoreError: Error, LocalizedError, Sendable {
    case notAvailable
    case unauthenticated
    case encodingFailed
    case decodingFailed
    case saveFailed(Error)
    case loadFailed(Error)
    public var errorDescription: String? {
        switch self {
        case .notAvailable: return "Store unavailable in this build."
        case .unauthenticated: return "User not authenticated."
        case .encodingFailed: return "Encoding failed."
        case .decodingFailed: return "Decoding failed."
        case .saveFailed(let e): return "Save failed: \(e.localizedDescription)"
        case .loadFailed(let e): return "Load failed: \(e.localizedDescription)"
        }
    }
}

public protocol RewardsStore: Sendable {
    func load() async throws -> RewardsWallet?
    func save(_ wallet: RewardsWallet) async throws
}

public struct UserDefaultsRewardsStore: RewardsStore, Sendable {
    private let key: String
    private let suite: UserDefaults
    public init(key: String = "rewards.wallet", suite: UserDefaults = .standard) {
        self.key = key
        self.suite = suite
    }
    public func load() async throws -> RewardsWallet? {
        guard let data = suite.data(forKey: key) else { return nil }
        do { return try JSONDecoder().decode(RewardsWallet.self, from: data) }
        catch { throw RewardsStoreError.decodingFailed }
    }
    public func save(_ wallet: RewardsWallet) async throws {
        do {
            let data = try JSONEncoder().encode(wallet)
            suite.set(data, forKey: key)
        } catch {
            throw RewardsStoreError.encodingFailed
        }
    }
}

#if canImport(CloudKit)
import CloudKit

public final class CloudKitRewardsStore: RewardsStore, @unchecked Sendable {
    private let container: CKContainer
    private let database: CKDatabase
    private let recordType = "RewardsWallet"
    private let recordID = CKRecord.ID(recordName: "wallet-singleton")
    public init(container: CKContainer = .default()) {
        self.container = container
        self.database = container.privateCloudDatabase
    }
    public func load() async throws -> RewardsWallet? {
        do {
            let record = try await database.record(for: recordID)
            guard let data = record["payload"] as? Data else { return nil }
            return try JSONDecoder().decode(RewardsWallet.self, from: data)
        } catch {
            // If not found, return nil rather than failing hard.
            if case CKError.unknownItem? = (error as NSError).userInfo[CKErrorDomain] { return nil }
            throw RewardsStoreError.loadFailed(error)
        }
    }
    public func save(_ wallet: RewardsWallet) async throws {
        do {
            let data = try JSONEncoder().encode(wallet)
            let record: CKRecord
            do { record = try await database.record(for: recordID) }
            catch { record = CKRecord(recordType: recordType, recordID: recordID) }
            record["payload"] = data as __CKRecordObjCValue
            _ = try await database.save(record)
        } catch {
            throw RewardsStoreError.saveFailed(error)
        }
    }
}
#endif

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
import FirebaseAuth
import FirebaseFirestore

public final class FirestoreRewardsStore: RewardsStore, @unchecked Sendable {
    private let db: Firestore
    private let path: (String) -> DocumentReference
    public init(db: Firestore = .firestore()) {
        self.db = db
        self.path = { uid in db.collection("users").document(uid).collection("private").document("wallet") }
    }
    public func load() async throws -> RewardsWallet? {
        guard let uid = Auth.auth().currentUser?.uid else { throw RewardsStoreError.unauthenticated }
        do {
            let snap = try await path(uid).getDocument()
            guard let data = snap.data(), let blob = data["payload"] as? Data else { return nil }
            return try JSONDecoder().decode(RewardsWallet.self, from: blob)
        } catch { throw RewardsStoreError.loadFailed(error) }
    }
    public func save(_ wallet: RewardsWallet) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { throw RewardsStoreError.unauthenticated }
        do {
            let blob = try JSONEncoder().encode(wallet)
            try await path(uid).setData(["payload": blob, "updatedAt": FieldValue.serverTimestamp()], merge: true)
        } catch { throw RewardsStoreError.saveFailed(error) }
    }
}
#else
public final class FirestoreRewardsStore: RewardsStore, @unchecked Sendable {
    public init() {}
    public func load() async throws -> RewardsWallet? { throw RewardsStoreError.notAvailable }
    public func save(_ wallet: RewardsWallet) async throws { throw RewardsStoreError.notAvailable }
}
#endif


