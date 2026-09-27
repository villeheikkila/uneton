import Foundation

enum LegalLinks {
    private static var languageQuery: String { Locale.current.identifier.hasPrefix("fi") ? "?lang=fi" : "" }
    static var privacy: URL { URL(string: "https://api.uneton.app/privacy\(languageQuery)")! }
    static var terms: URL { URL(string: "https://api.uneton.app/terms\(languageQuery)")! }
}
