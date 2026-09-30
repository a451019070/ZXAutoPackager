import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
            return Locale(identifier: preferred.hasPrefix("zh") ? "zh-Hans" : "en")
        case .chinese: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        }
    }

    var bundle: Bundle {
        let language = locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}

enum AppStrings {
    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "ZXAutoPackager.language") ?? "system") ?? .system
    }

    static func text(_ key: String) -> String {
        language.bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
