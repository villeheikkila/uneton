import Foundation
import Testing
@testable import Uneton

struct LocalizationTests {
    @Test func `English and Finnish strings resolve from the app catalog`() {
        let english = Locale(identifier: "en_US")
        let finnish = Locale(identifier: "fi_FI")

        #expect(localized(.locImportHuckleberry, in: english) == "Import from Huckleberry")
        #expect(localized(.locImportHuckleberry, in: finnish) == "Tuo Huckleberrystä")
        #expect(localized(.locImportPreview("12", "3"), in: finnish) == "Tuotavia unijaksoja: 12. Ohitettuja rivejä: 3.")
        #expect(localized(.locImportQueued("1"), in: english) == "Sleep records added: 1. They will sync with your family when connected.")
        #expect(localized(.locAddBaby, in: english) == "Add baby")
        #expect(localized(.locAddBaby, in: finnish) == "Lisää vauva")
        #expect(localized(.locChildWokeUp("Aino"), in: english) == "Aino woke up")
        #expect(localized(.locChildWokeUp("Aino"), in: finnish) == "Aino heräsi")
    }

    private func localized(_ value: LocalizedStringResource, in locale: Locale) -> String {
        var value = value
        value.locale = locale
        return String(localized: value)
    }
}
