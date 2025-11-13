//  Services/Rewards/RewardsManager.swift
//  SKATEROUTE
//

import Foundation
import Combine

@MainActor
public final class RewardsManager: ObservableObject {
    @Published public private(set) var wallet: RewardsWallet

    private let primary: any RewardsStore
    private let backup: (any RewardsStore)?
    private var autosaveCancellable: AnyCancellable?

    public init(primary: any RewardsStore,
                backup: (any RewardsStore)? = nil,
                seed: RewardsWallet = RewardsWallet()) {
        self.primary = primary
        self.backup = backup
        self.wallet = seed
        // Autosave on any wallet mutation (debounced)
        autosaveCancellable = $wallet
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] w in
                Task { try? await self?.persist(w) }
            }
    }

    public func bootstrap() async {
        if let loaded = try? await primary.load() ?? (try? await backup?.load() ?? nil) {
            wallet = loaded
        } else {
            // first-run seed write
            try? await persist(wallet)
        }
    }

    public func earn(_ event: EarnEvent, now: Date = .init()) throws {
        var w = wallet
        _ = try w.earn(event, now: now)
        wallet = w
    }

    public func redeem(cost: Int, productId: String, now: Date = .init()) throws {
        var w = wallet
        _ = try w.redeem(cost: cost, productId: productId, now: now)
        wallet = w
    }

    public func awardBadge(_ id: String, now: Date = .init()) {
        var w = wallet
        w.awardBadge(id, now: now)
        wallet = w
    }

    public func reset(now: Date = .init()) {
        var w = wallet
        w.reset(now: now)
        wallet = w
    }

    private func persist(_ w: RewardsWallet) async throws {
        try await primary.save(w)
        if let backup { try? await backup.save(w) }
    }
}


