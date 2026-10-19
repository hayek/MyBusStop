import Testing
@testable import BusBus

/// Runs a suite in one language, whatever was last chosen in Settings on the device the tests
/// happen to run on — they share the app's defaults, so a simulator left in Arabic would otherwise
/// fail every check of an English caption.
nonisolated struct AppLanguageTrait: SuiteTrait, TestTrait, TestScoping {
    var code: String
    var isRecursive: Bool { true }

    // Spelled out because this target makes async closures nonsending by default and the
    // framework's requirement predates that.
    @concurrent func provideScope(for test: Test, testCase: Test.Case?,
                                  performing function: @concurrent @Sendable () async throws -> Void) async throws {
        try await AppLanguage.$pinned.withValue(code) { try await function() }
    }
}

extension Trait where Self == AppLanguageTrait {
    static func appLanguage(_ code: String) -> Self { AppLanguageTrait(code: code) }
}
