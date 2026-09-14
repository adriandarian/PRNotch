import SwiftUI

struct NotchRailEntryView: View {
    @ObservedObject var store: PullRequestStore
    let entry: NotchRailEntry
    let centerFromTop: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var isSelected: Bool {
        store.isExpanded && store.selectedEntryID == entry.id
    }

    private var isEmphasized: Bool {
        isHovered || isSelected
    }

    var body: some View {
        Button {
            withAnimation(animation) {
                store.activateEntry(id: entry.id, centerFromTop: centerFromTop)
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .stroke(entryColor.opacity(0.18), lineWidth: 4)
                        .frame(width: NotchLayout.ringDiameter + 5, height: NotchLayout.ringDiameter + 5)
                        .blur(radius: 2.5)
                }

                Circle()
                    .fill(Color.black.opacity(isEmphasized ? 0.30 : 0.22))
                    .overlay {
                        Circle()
                            .strokeBorder(
                                entryColor.opacity(isEmphasized ? 1 : 0.88),
                                lineWidth: isEmphasized ? 1.75 : 1.25
                            )
                    }
                    .shadow(
                        color: entryColor.opacity(isEmphasized ? 0.28 : 0.10),
                        radius: isEmphasized ? 4 : 2
                    )
                    .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)

                entryLabel
            }
            .scaleEffect(isHovered ? 1.03 : 1)
            // Keep the hit target as wide as the hosting panel, while centering
            // the visible node within the narrower expanded rail body.
            .frame(width: NotchLayout.railWidth, height: 44)
            .frame(width: NotchLayout.railPanelWidth, height: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            withAnimation(animation) {
                isHovered = hovering
            }
            if hovering {
                store.previewEntry(id: entry.id, centerFromTop: centerFromTop)
            } else {
                store.endPreview(id: entry.id)
            }
        }
        .accessibilityLabel(helpText)
        .accessibilityHint(isSelected ? "Collapses details" : "Shows pull request details")
    }

    @ViewBuilder
    private var entryLabel: some View {
        switch entry {
        case .pullRequest(let pullRequest):
            Text(verbatim: "\(pullRequest.number)")
                .font(.system(
                    size: numberFontSize(for: pullRequest.number),
                    weight: .semibold,
                    design: .rounded
                ))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: NotchLayout.ringDiameter - 6)
        case .message(let message):
            Image(systemName: symbolName(for: message.kind))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.94))
        }
    }

    private var entryColor: Color {
        switch entry {
        case .pullRequest(let pullRequest): pullRequest.attention.color
        case .message(let message):
            switch message.kind {
            case .loading: .prWaiting
            case .empty: .prReady
            case .unavailable: .prNeutral
            }
        }
    }

    private var helpText: String {
        switch entry {
        case .pullRequest(let pullRequest):
            let base = "\(pullRequest.repository) #\(pullRequest.number): \(pullRequest.title) — \(pullRequest.attentionTitle)"
            guard let relationship = store.relationshipSummary(for: pullRequest.id) else {
                return base
            }
            return "\(base) — \(relationship)"
        case .message(let message):
            return "\(message.title): \(message.detail)"
        }
    }

    private func symbolName(for kind: NotchMessageKind) -> String {
        switch kind {
        case .loading: "arrow.triangle.2.circlepath"
        case .empty: "checkmark"
        case .unavailable: "exclamationmark"
        }
    }

    private func numberFontSize(for number: Int) -> CGFloat {
        switch String(abs(number)).count {
        case 0...2: 9.5
        case 3: 8
        case 4: 6.75
        default: 6
        }
    }

    private var animation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.30, dampingFraction: 0.78)
    }
}
