// Features/Map/Views/RoutePlannerView.swift
import SwiftUI

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

            LayerToggleBar(layers: RoutePlannerViewModel.PlannerLayer.allCases,
                           selection: $viewModel.activeLayers)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.isLoading && viewModel.options.isEmpty {
                ProgressView("Loading routes…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.options) { option in
                            optionCard(for: option)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            ElevationProfileView(summary: viewModel.slopeSummary)

            actionRow
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 12)
    }

    private func optionCard(for option: RouteOptionModel) -> some View {
        let isSelected = viewModel.selectedOption?.id == option.id
        return Button {
            viewModel.select(option: option)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(option.title)
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.0f", option.score * 100))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(option.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label(option.distanceString, systemImage: "map")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(option.etaString, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(option.scoreLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if option.mkRoute == nil {
                    Text("Offline snapshot")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(width: 220)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color(UIColor.secondarySystemBackground))
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
            .disabled(viewModel.selectedOption == nil)

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
            .disabled(viewModel.selectedOption == nil)
        }
    }

    private var iconForDownloadState: String {
        switch viewModel.downloadState {
        case .idle: return "tray.and.arrow.down"
        case .downloading: return "arrow.down.circle"
        case .cached: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var titleForDownloadState: String {
        switch viewModel.downloadState {
        case .idle:
            return "Download for offline"
        case .downloading(let progress):
            return "Downloading \(Int(progress * 100))%"
        case .cached:
            return "Offline ready"
        case .failed:
            return "Retry download"
        }
    }
}
