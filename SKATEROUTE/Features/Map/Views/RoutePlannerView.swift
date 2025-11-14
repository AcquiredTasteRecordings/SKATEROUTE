// Features/Map/Views/RoutePlannerView.swift
import SwiftUI
import UIKit

public struct RoutePlannerView: View {
    @ObservedObject private var viewModel: RoutePlannerViewModel
    @Binding private var isRiding: Bool
    private let onRideAction: () -> Void

    public init(viewModel: RoutePlannerViewModel,
                isRiding: Binding<Bool>,
                onRideAction: @escaping () -> Void) {
        self.viewModel = viewModel
        self._isRiding = isRiding
        self.onRideAction = onRideAction
    }

    public var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 38, height: 4)
                .padding(.top, 8)

            content

            actionRow
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            stateView

            if let banner = viewModel.bannerText, !banner.isEmpty {
                Text(banner)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            offlineStatusView
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch viewModel.state {
        case .idle:
            Text("Pick a start and end point to plan a route.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Planning routes…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .loaded:
            if viewModel.orderedCandidateIDs.isEmpty {
                Text("No routes available. Try adjusting your request.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                routeCarousel
            }
        case .error(let message):
            Text(message)
                .font(.footnote)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var routeCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(viewModel.orderedCandidateIDs, id: \.self) { id in
                    candidateCard(for: id)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("RoutePlannerView.OptionsCarousel")
    }

    private func candidateCard(for id: String) -> some View {
        let presentation = viewModel.presentations[id]
        let isSelected = viewModel.selectedCandidateID == id
        let tint = Color(uiColor: presentation?.tintColor ?? .systemBlue)

        return Button {
            viewModel.selectCandidate(id: id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(presentation?.title ?? NSLocalizedString("Route", comment: "fallback route title"))
                        .font(.headline)
                    Spacer()
                    if let score = presentation?.score {
                        Text(String(format: "%.0f", score))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(presentation?.subtitle ?? NSLocalizedString("Loading details…", comment: "route subtitle placeholder"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 12) {
                    Label(presentation?.distanceText ?? "—", systemImage: "map")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(presentation?.etaText ?? "—", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(presentation?.scoreLabel ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 240, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.18) : Color(UIColor.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? tint : Color(UIColor.separator).opacity(0.4), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(presentation?.title ?? "Route option"))
        .accessibilityHint(Text("Select route option"))
    }

    private var offlineStatusView: some View {
        let status = offlineStatusDescription(for: viewModel.offlineState)

        return HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.caption)
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(status.accessibilityLabel))
    }

    private func offlineStatusDescription(for state: OfflineTileManager.DownloadState) -> (title: String, detail: String?, symbol: String, accessibilityLabel: String) {
        switch state {
        case .idle:
            let text = NSLocalizedString("Offline: Idle", comment: "offline idle state")
            return (text, nil, "icloud.slash", text)
        case .preparing:
            let text = NSLocalizedString("Offline: Preparing", comment: "offline preparing state")
            return (text, nil, "gearshape", text)
        case .downloading(let progress):
            let percent = Int(progress * 100)
            let title = NSLocalizedString("Offline: Downloading", comment: "offline downloading state")
            let detail = String(format: NSLocalizedString("%d%% complete", comment: "offline progress detail"), percent)
            return (title, detail, "arrow.down.circle", "\(title), \(detail)")
        case .cached(let tileCount):
            let title = NSLocalizedString("Offline: Ready", comment: "offline ready state")
            let detail = String(format: NSLocalizedString("%d tiles", comment: "offline tile count detail"), tileCount)
            return (title, detail, "checkmark.circle", "\(title), \(detail)")
        case .failed(let message):
            let title = NSLocalizedString("Offline: Failed", comment: "offline failed state")
            return (title, message, "exclamationmark.triangle", "\(title), \(message)")
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(action: onRideAction) {
                HStack {
                    Image(systemName: "skateboard")
                    Text(isRiding ? "Stop Ride" : "Start Ride")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(isRiding ? Color.red : Color.accentColor)
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .disabled(viewModel.selectedCandidateID == nil)
        }
    }
}


