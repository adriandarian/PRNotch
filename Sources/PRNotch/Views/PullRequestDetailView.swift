import SwiftUI

struct PullRequestDetailView: View {
    @ObservedObject var store: PullRequestStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            detailSurface

            if let entry = store.selectedEntry {
                detailContent(for: entry)
                    .id(entry.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(width: selectedDetailSize.width, height: selectedDetailSize.height)
        .contentShape(LiquidDetailShape(pointerCenter: store.detailPointerCenter))
        .onHover { isInside in
            store.surfaceHoverChanged(.detail, isInside: isInside)
        }
        .onExitCommand {
            store.collapse()
        }
        .animation(contentAnimation, value: store.selectedEntryID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pull request details")
    }

    private var detailSurface: some View {
        LiquidDetailShape(pointerCenter: store.detailPointerCenter)
            .fill(Color.notchBlack)
            .overlay {
                LiquidDetailShape(pointerCenter: store.detailPointerCenter)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.07),
                                Color.clear,
                                Color.black.opacity(0.18),
                            ],
                            startPoint: .topTrailing,
                            endPoint: .bottomLeading
                        )
                    )
            }
            .overlay {
                LiquidDetailShape(pointerCenter: store.detailPointerCenter)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.75)
            }
    }

    @ViewBuilder
    private func detailContent(for entry: NotchRailEntry) -> some View {
        switch entry {
        case .pullRequest(let pullRequest):
            pullRequestContent(pullRequest)
        case .message(let message):
            messageContent(message)
        }
    }

    private func pullRequestContent(_ pullRequest: PullRequest) -> some View {
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Text("\(pullRequest.repository)  #\(pullRequest.number)")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .help(pullRequest.repository)
            }

            Button { AppActions.open(pullRequest.url) } label: {
                Text(pullRequest.title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.97))
                    .lineLimit(3)
                    .minimumScaleFactor(0.90)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(pullRequest.repository) #\(pullRequest.number) on GitHub")

            PullRequestStatusLine(pullRequest: pullRequest)

            if !pullRequest.reviewers.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Divider()
                        .overlay(Color.white.opacity(0.10))

                    Text("Review activity")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                        .textCase(.uppercase)

                    HStack(spacing: 10) {
                        ForEach(Array(pullRequest.reviewers.prefix(6))) { reviewer in
                            ReviewerAvatar(reviewer: reviewer)
                        }

                        if pullRequest.reviewers.count > 6 {
                            Text("+\(pullRequest.reviewers.count - 6)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.70))
                                .frame(width: 29, height: 29)
                                .background(Color.white.opacity(0.08), in: Circle())
                                .help("\(pullRequest.reviewers.count - 6) more reviewers")
                        }
                    }
                }
            }

            HStack {
                Spacer()
                detailUpdateStatus
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(.top, 2)
        }
        .padding(.leading, 34)
        .padding(.trailing, 18)
        .padding(.vertical, 16)
    }

    private var selectedDetailSize: CGSize {
        NotchLayout.detailSize(for: store.selectedEntry)
    }

    private var detailUpdateStatus: Text {
        switch store.dataState {
        case .loading:
            return Text("Updating…")
        case .live:
            return Text("Updated just now")
        case .outOfDate(let date, _):
            guard let date else { return Text("Not updated yet") }
            return Text("Updated ") +
                Text(date, style: .relative) +
                Text(" ago")
        }
    }

    private func messageContent(_ message: NotchMessage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(messageColor(message.kind).opacity(0.18))
                    Image(systemName: messageSymbol(message.kind))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(messageColor(message.kind))
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.title)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                    Text(store.sourceCaption)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }

            Text(message.detail)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .lineSpacing(3)
                .textSelection(.enabled)

            if message.kind == .unavailable {
                Text(store.requiresGitHubSignIn
                    ? "PR Notch uses the GitHub CLI already installed on this Mac. Sign in once, then refresh—no browser tabs need to stay open."
                    : "PR Notch will retry automatically. You can also retry now.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineSpacing(2)
            }

            Spacer()

            HStack(spacing: 9) {
                if message.kind == .unavailable, store.requiresGitHubSignIn {
                    detailButton("Copy gh login", symbol: "doc.on.doc") {
                        AppActions.copyGitHubLoginCommand()
                    }
                }

                detailButton(store.isRefreshing ? "Refreshing…" : "Refresh now", symbol: "arrow.clockwise") {
                    store.requestRefresh()
                }
                .disabled(store.isRefreshing)
            }
        }
        .padding(.leading, 34)
        .padding(.trailing, 18)
        .padding(.vertical, 20)
    }

    private func detailButton(
        _ title: String,
        symbol: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.90))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.09), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func messageColor(_ kind: NotchMessageKind) -> Color {
        switch kind {
        case .loading: .prWaiting
        case .empty: .prReady
        case .unavailable: .prNeutral
        }
    }

    private func messageSymbol(_ kind: NotchMessageKind) -> String {
        switch kind {
        case .loading: "arrow.triangle.2.circlepath"
        case .empty: "checkmark"
        case .unavailable: "exclamationmark"
        }
    }

    private var contentAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.34, dampingFraction: 0.84)
    }
}

private struct PullRequestStatusLine: View {
    let pullRequest: PullRequest

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(pullRequest.attention.color.opacity(0.18))
                Image(systemName: pullRequest.attention.symbolName)
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(pullRequest.attention.color)
            }
            .frame(width: 21, height: 21)

            VStack(alignment: .leading, spacing: 1) {
                Text(pullRequest.attentionTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                Text(pullRequest.attentionSummary)
                    .font(.system(size: 9.5, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
            }
            .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}

private extension PullRequestReviewer {
    var avatarURL: URL? {
        URL(string: "https://github.com/\(login).png?size=64")
    }

    var initials: String {
        String(login.prefix(2)).uppercased()
    }

    var statusSymbol: String {
        switch state.uppercased() {
        case "APPROVED": "checkmark"
        case "CHANGES_REQUESTED": "xmark"
        case "COMMENTED": leftComments ? "bubble.left.fill" : "eye.fill"
        default: leftComments ? "bubble.left.fill" : "eye.fill"
        }
    }

    var statusColor: Color {
        switch state.uppercased() {
        case "APPROVED": .prReady
        case "CHANGES_REQUESTED": .prFailing
        case "COMMENTED": leftComments ? .prFeedback : .prNeutral
        default: leftComments ? .prFeedback : .prNeutral
        }
    }

    var statusForeground: Color {
        switch state.uppercased() {
        case "APPROVED": Color.black.opacity(0.78)
        case "COMMENTED": leftComments ? Color.black.opacity(0.78) : .white
        default: .white
        }
    }

    var displayName: String {
        name.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? login
    }

    var helpText: String {
        let status = switch state.uppercased() {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Requested changes"
        case "COMMENTED": leftComments ? "Active comment" : "Commented previously"
        default: "Reviewed"
        }
        let commentSuffix = leftComments && state.uppercased() != "COMMENTED" ? " · active comment" : ""
        return "\(displayName) (@\(login)) · \(status)\(commentSuffix)"
    }
}

private struct ReviewerAvatar: View {
    let reviewer: PullRequestReviewer
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .top) {
            AsyncImage(url: reviewer.avatarURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(reviewer.initials)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.10))
                }
            }
            .frame(width: 31, height: 31)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    Circle().fill(Color.notchBlack)
                    Circle().fill(reviewer.statusColor.opacity(0.95)).padding(2)
                    Image(systemName: reviewer.statusSymbol)
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(reviewer.statusForeground)
                }
                .frame(width: 14, height: 14)
                .offset(x: 3, y: 3)
            }
            .contentShape(Circle())

            if isHovering {
                Text(reviewer.displayName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.notchBlack.opacity(0.96), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
                    .offset(y: -30)
                    .zIndex(1)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 31, height: 31)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .help(reviewer.helpText)
        .accessibilityLabel(reviewer.helpText)
    }
}
