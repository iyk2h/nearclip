import Foundation

enum AppLanguage {
    static let preferenceKey = "interfaceLanguage"
    static let current = UserDefaults.standard.string(forKey: preferenceKey) == "ko" ? "ko" : "en"
    static let translations: Bundle? = current == "ko"
        ? Bundle.main.url(forResource: "ko", withExtension: "lproj").flatMap(Bundle.init(url:))
        : nil
}

func ui(_ english: String, _ arguments: String...) -> String {
    let text = AppLanguage.translations?.localizedString(forKey: english, value: english, table: nil) ?? english
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}
