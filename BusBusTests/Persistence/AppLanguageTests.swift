import Testing
import Foundation
import SwiftUI
@testable import BusBus

@MainActor
struct AppLanguageTests {

    @Test func aChosenLanguageSurvivesARelaunchAndSeedsTheNextLaunch() {
        let defaults = UserDefaults(suiteName: "language-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        #expect(store.language == nil)

        store.language = "he"
        #expect(SettingsStore(defaults: defaults).language == "he")
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["he"])
    }

    @Test func goingBackToTheDeviceLanguageForgetsTheOverride() {
        let suite = "language-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        store.language = "ar"
        store.language = nil

        #expect(SettingsStore(defaults: defaults).language == nil)
        // Reading the key would fall through to the system's own list; what matters is that the
        // app no longer holds one of its own.
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
    }

    @Test func aLanguageTheAppDoesNotSpeakIsIgnored() {
        let defaults = UserDefaults(suiteName: "language-\(UUID().uuidString)")!
        defaults.set("tlh", forKey: AppLanguage.defaultsKey)
        #expect(SettingsStore(defaults: defaults).language == nil)
    }

    @Test func eachLanguageIsNamedInItself() {
        #expect(AppLanguage.name(of: "he") == "עברית")
        #expect(AppLanguage.name(of: "de") == "Deutsch")
        #expect(AppLanguage.name(of: "ja") == "日本語")
        #expect(AppLanguage.name(of: "hmn-Latn") == "Hmoob")
    }

    @Test func onlyArabicAndHebrewReadRightToLeft() {
        let rtl = AppLanguage.supported.filter { AppLanguage.layoutDirection(for: $0) == .rightToLeft }
        #expect(Set(rtl) == ["ar", "he"])
    }

    /// Two Portugueses and two Chinese scripts sit in one list; each has to be told apart.
    @Test func noTwoLanguagesShareAName() {
        let names = AppLanguage.supported.map(AppLanguage.name(of:))
        #expect(Set(names).count == names.count, "\(names)")
    }

    /// Every country BusBus serves can have the app in its own language.
    @Test func everyServedCountrysLanguageIsOffered() {
        let needed = ["he", "ar", "en", "nb", "fi", "sv", "pt-PT", "fr", "pl", "zh-Hant", "de", "it", "ja",
                      "tr", "et", "lt"]
        #expect(Set(needed).isSubset(of: Set(AppLanguage.supported)))
    }

    /// And the big communities riding its buses: Amharic in Israel, Vietnamese in Seattle, Somali
    /// and Hmong in Minneapolis, Tagalog (as Filipino) and Punjabi in Toronto, and Nynorsk beside
    /// Bokmål.
    @Test func theLargestRiderCommunitiesLanguagesAreOffered() {
        let needed = ["am", "vi", "so", "hmn-Latn", "fil", "pa", "nn"]
        #expect(Set(needed).isSubset(of: Set(AppLanguage.supported)))
    }

    /// And the newer regions': Dutch in Brussels, Slovenian in Ljubljana, Basque in Bizkaia, Czech
    /// in Prague, Hungarian in Budapest and Romanian in Cluj.
    @Test func theNewerRegionsLanguagesAreOffered() {
        let needed = ["nl", "sl", "eu", "cs", "hu", "ro"]
        #expect(Set(needed).isSubset(of: Set(AppLanguage.supported)))
        #expect(AppLanguage.name(of: "nl") == "Nederlands")
        #expect(AppLanguage.name(of: "cs") == "Čeština")
    }

    /// Letter-spaced monospace is kept for the alphabets it was drawn for; Hebrew, Arabic, Ethiopic,
    /// the Indic and the CJK scripts are set solid in the proportional face.
    @Test func onlyLatinCyrillicAndGreekAreTracked() {
        for code in ["en", "de", "fi", "nb", "nn", "pl", "pt-PT", "ru", "sv", "tr", "et", "lt",
                     "vi", "so", "hmn-Latn", "fil", "nl", "sl", "eu", "cs", "hu", "ro"] {
            #expect(LocaleAwareBusFont.isTracked(Locale(identifier: code)), "\(code)")
        }
        for code in ["he", "ar", "hi", "ja", "ko", "zh-Hans", "zh-Hant", "am", "pa"] {
            #expect(!LocaleAwareBusFont.isTracked(Locale(identifier: code)), "\(code)")
        }
    }

    /// A stop's name is set by its own script, whatever the app's language.
    @Test func stopNamesAreTrackedByTheirOwnScript() {
        for name in ["5 AV/W 42 ST", "RONDO KAPONIERA", "BEŞİKTAŞ ÇARŞI", "МАЙОРСТУЕН", "TRẠM XE"] {
            #expect(LocaleAwareBusFont.isTracked(name), "\(name)")
        }
        for name in ["כיכר רבין", "銀座四丁目", "محطة السلطان سليمان", "香港文化中心"] {
            #expect(!LocaleAwareBusFont.isTracked(name), "\(name)")
        }
    }

    /// The string catalog, not just the code, has to carry every language offered in Settings.
    @Test func everyOfferedLanguageShipsInTheBundle() {
        let shipped = Set(Bundle.main.localizations)
        #expect(Set(AppLanguage.supported).isSubset(of: shipped))
    }

    /// Spot checks that the welcome story is translated: a key missing from the catalog would show
    /// in English in every language. (The page counter is left out: "3 / 3" is a correct Hebrew
    /// translation of itself.)
    @Test(.appLanguage("he"))
    func theWelcomeStoryIsTranslated() {
        #expect(String(appLocalized: "Tap the stop name any time to change the stop or its lines.")
                != "Tap the stop name any time to change the stop or its lines.")
        #expect(String(appLocalized: "Find stops near you.") != "Find stops near you.")
    }
}
