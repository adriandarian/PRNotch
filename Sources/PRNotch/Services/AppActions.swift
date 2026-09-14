import AppKit

enum AppActions {
    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func quit() {
        NSApp.terminate(nil)
    }

    @MainActor
    static func copyGitHubLoginCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("gh auth login -h github.com", forType: .string)
    }

    @MainActor
    static func copyPullRequestMarkdown(_ pullRequests: [PullRequest]) {
        let attributed = PullRequestMarkdownFormatter.attributedReviewRequest(pullRequests)
        guard attributed.length > 0 else { return }

        let fullRange = NSRange(location: 0, length: attributed.length)
        let rtf = try? attributed.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let html = try? attributed.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.html, .rtf, .string], owner: nil)
        if let html { pasteboard.setData(html, forType: .html) }
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
        pasteboard.setString(
            PullRequestMarkdownFormatter.plainTextReviewRequest(pullRequests),
            forType: .string
        )
    }
}

enum PullRequestMarkdownFormatter {
    private struct Group {
        let label: String
        var pullRequests: [PullRequest]
    }

    static func render(_ pullRequests: [PullRequest]) -> String {
        guard !pullRequests.isEmpty else { return "" }
        let items = groups(pullRequests).map { group in
            "* \(group.label): \(group.pullRequests.map(markdownLink).joined(separator: ", "))"
        }
        return "Could I get reviews on these PRs? :pray:\n" + items.joined(separator: "\n")
    }

    static func plainTextReviewRequest(_ pullRequests: [PullRequest]) -> String {
        guard !pullRequests.isEmpty else { return "" }
        let lines = groups(pullRequests).map { group in
            "* \(group.label): \(group.pullRequests.map { $0.url.absoluteString }.joined(separator: ", "))"
        }
        return "Could I get reviews on these PRs? :pray:\n" + lines.joined(separator: "\n")
    }

    static func attributedReviewRequest(_ pullRequests: [PullRequest]) -> NSAttributedString {
        guard !pullRequests.isEmpty else { return NSAttributedString() }
        let result = NSMutableAttributedString(string: "Could I get reviews on these PRs? :pray:")

        for group in groups(pullRequests) {
            result.append(NSAttributedString(string: "\n* \(group.label): "))
            for (index, pullRequest) in group.pullRequests.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: ", ")) }
                result.append(NSAttributedString(
                    string: "\(pullRequest.repositoryName) #\(pullRequest.number)",
                    attributes: [.link: pullRequest.url]
                ))
            }
        }
        return result
    }

    static func issueKey(in value: String) -> String? {
        guard let range = value.range(
            of: #"(?<![A-Z0-9])[A-Z][A-Z0-9]+-\d+(?![A-Z0-9])"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        return value[range].uppercased()
    }

    private static func groups(_ pullRequests: [PullRequest]) -> [Group] {
        var groups: [Group] = []
        for pullRequest in pullRequests {
            let label = issueKey(in: pullRequest.relationshipText) ?? "Other"
            if let index = groups.firstIndex(where: { $0.label == label }) {
                groups[index].pullRequests.append(pullRequest)
            } else {
                groups.append(Group(label: label, pullRequests: [pullRequest]))
            }
        }
        return groups.filter { $0.label != "Other" } + groups.filter { $0.label == "Other" }
    }

    private static func markdownLink(to pullRequest: PullRequest) -> String {
        "[\(pullRequest.repositoryName) #\(pullRequest.number)](\(pullRequest.url.absoluteString))"
    }
}
