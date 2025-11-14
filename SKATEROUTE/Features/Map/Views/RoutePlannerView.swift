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

            if case .error(let message) = viewModel.state {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .loading = viewModel.state, orderedOptions.isEmpty {
                ProgressView("Loading routes…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !orderedOptions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(orderedOptions, id: \.id) { option in
                            optionCard(for: option)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let banner = viewModel.bannerText {
                Text(banner)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ElevationProfileView(summary: selectedGradeSummary)

            actionRow
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 12)
    }

    private var orderedOptions: [RouteOption] {
        viewModel.orderedCandidateIDs.compactMap { id in
            guard let presentation = viewModel.presentations[id] else { return nil }
            return RouteOption(id: id, presentation: presentation)
        }
    }

    private var selectedGradeSummary: GradeSummary? {
        guard let id = viewModel.selectedCandidateID else { return nil }
        return viewModel.gradeSummaries[id]
    }

    private func optionCard(for option: RouteOption) -> some View {
        let isSelected = viewModel.selectedCandidateID == option.id
        return Button {
            viewModel.selectCandidate(id: option.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(option.presentation.title)
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.0f", option.presentation.score))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(option.presentation.tintColor).opacity(0.12))
                        .clipShape(Capsule())
                        .foregroundColor(Color(option.presentation.tintColor))
                }

                Text(option.presentation.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label(option.presentation.distanceText, systemImage: "map")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(option.presentation.etaText, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(option.presentation.scoreLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(width: 220)
            .background(isSelected ? Color(option.presentation.tintColor).opacity(0.18) : Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(action: viewModel.downloadSelectedForOffline) {
                HStack {
                    Image(systemName: iconForDownloadState)
                    Text(titleForDownloadState)
                }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(Capsule())
            }
            .disabled(viewModel.selectedCandidateID == nil)

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

    private var iconForDownloadState: String {
        switch viewModel.offlineState {
        case .idle: return "tray.and.arrow.down"
        case .preparing: return "clock"
        case .downloading: return "arrow.down.circle"
        case .cached: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var titleForDownloadState: String {
        switch viewModel.offlineState {
        case .idle:
            return "Download for offline"
        case .preparing:
            return "Preparing tiles…"
        case .downloading(let progress):
            return "Downloading \(Int(progress * 100))%"
        case .cached(let count):
            return count > 0 ? "Offline ready (\(count))" : "Offline ready"
        case .failed:
            return "Retry download"
        }
    }
}

private struct RouteOption: Identifiable {
    let id: String
    let presentation: RouteOptionsReducer.Presentation
}


