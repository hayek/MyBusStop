import Foundation
import LoveLetterCore

/// In-app feedback: a report from the stop picker's speech bubble becomes an issue in
/// hayek/my-bus-stop-feedback, which the Love Letter inbox reads.
///
/// The token is a fine-grained GitHub token limited to that one repository (Issues and Contents,
/// for the sheet's photo attachments). Unlike the transit keys it ships in Release too, so anyone who
/// extracts it can at most file issues there. It reaches the Info.plist from the gitignored
/// Config/Feedback.xcconfig (scripts/fill-secrets.sh); a build without it has no feedback button.
enum Feedback {
    static let infoDictionaryKey = "LoveLetterGitHubToken"

    /// Nil when this build carries no token.
    static let client: FeedbackClient? = token.map {
        FeedbackClient(appName: "My Bus Stop",
                       transport: GitHubDirectTransport(owner: "hayek", repo: "my-bus-stop-feedback", token: $0))
    }

    /// Empty, or a build setting that was never expanded ("$(LOVELETTER_GITHUB_TOKEN)"), is no token.
    private static var token: String? {
        guard let value = (Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
