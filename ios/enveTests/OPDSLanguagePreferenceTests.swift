import Foundation
import Testing

@testable import enve

struct OPDSLanguagePreferenceTests {
    private let titles = ["en": "The Silent Yard", "fr": "Le chantier silencieux", "ja": "静かな造船所"]

    @Test func theReadersOwnLanguageWins() {
        #expect(OPDSLanguagePreference.select(from: titles, preferring: ["fr-FR"]) == "Le chantier silencieux")
        #expect(OPDSLanguagePreference.select(from: titles, preferring: ["ja"]) == "静かな造船所")
    }

    /// BCP 47 lookup falls back along the tag, so a reader who asked for `fr-CA` still gets `fr`.
    @Test func aRegionalTagMatchesItsBaseLanguage() {
        #expect(OPDSLanguagePreference.select(from: titles, preferring: ["fr-CA"]) == "Le chantier silencieux")
        #expect(
            OPDSLanguagePreference.select(from: ["pt-BR": "Estaleiro"], preferring: ["pt"]) == "Estaleiro"
        )
    }

    @Test func theOrderOfTheReadersLanguagesIsRespected() {
        #expect(OPDSLanguagePreference.select(from: titles, preferring: ["de", "ja", "fr"]) == "静かな造船所")
    }

    @Test func englishIsTheFallbackWhenNothingMatches() {
        #expect(OPDSLanguagePreference.select(from: titles, preferring: ["de"]) == "The Silent Yard")
    }

    @Test func readiumsUndefinedKeyIsUsedWhenThereIsNoEnglish() {
        #expect(
            OPDSLanguagePreference.select(from: ["und": "Untitled", "de": "Ohne Titel"], preferring: ["fr"])
                == "Untitled"
        )
    }

    /// Two runs of the same catalog must not disagree about a title.
    @Test func theLastResortIsDeterministic() {
        let choices = ["ru": "Прогулка", "de": "Spaziergang"]

        #expect(OPDSLanguagePreference.select(from: choices, preferring: ["ja"]) == "Spaziergang")
        #expect(OPDSLanguagePreference.select(from: choices, preferring: ["ja"]) == "Spaziergang")
    }

    @Test func nothingToChooseFromYieldsNothing() {
        #expect(OPDSLanguagePreference.select(from: [:], preferring: ["en"]) == nil)
    }

    @Test func aTagIsMatchedWithoutRegardToCase() {
        #expect(OPDSLanguagePreference.select(from: ["EN-GB": "Yard"], preferring: ["en-gb"]) == "Yard")
    }
}
