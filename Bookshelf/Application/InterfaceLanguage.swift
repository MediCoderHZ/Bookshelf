import Foundation
import Observation

enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
  case chinese = "zh-Hans"
  case english = "en"
  var id: Self { self }
  var title: String { self == .chinese ? "简体中文" : "English" }
  var locale: Locale { Locale(identifier: rawValue) }
}

/// Observation updates existing views without recreating their editing state.
/// Core services also use this lookup, so preference access is synchronized.
@Observable
final class InterfaceLanguagePreferences: @unchecked Sendable {
  // Match the language AppKit loaded for this process, including first launch
  // and a language selected in macOS's per-application language settings.
  static let shared = InterfaceLanguagePreferences(launchLanguage:
    Bundle.main.bundleURL.pathExtension != "app" ? .chinese :
      (Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? .chinese : .english))
  static let preferenceKey = "interfaceLanguage"
  @ObservationIgnored private let preferences: UserDefaults
  @ObservationIgnored private let lock = NSLock()
  @ObservationIgnored private var storedLanguage: InterfaceLanguage
  @ObservationIgnored private var storedRequestedLanguage: InterfaceLanguage

  init(preferences: UserDefaults = .standard, launchLanguage: InterfaceLanguage? = nil) {
    self.preferences = preferences
    let saved = preferences.string(forKey: Self.preferenceKey).flatMap(InterfaceLanguage.init(rawValue:))
    storedRequestedLanguage = saved ?? launchLanguage ?? .chinese
    storedLanguage = launchLanguage ?? storedRequestedLanguage
  }

  /// Stage a language for the next process. Never partially change the current
  /// interface while AppKit, file panels and Sparkle still use their launch language.
  var requestedLanguage: InterfaceLanguage {
    get {
      access(keyPath: \.requestedLanguage)
      return lock.withLock { storedRequestedLanguage }
    }
    set {
      withMutation(keyPath: \.requestedLanguage) {
        lock.withLock {
          storedRequestedLanguage = newValue
          preferences.set(newValue.rawValue, forKey: Self.preferenceKey)
        }
      }
    }
  }
  var requiresRelaunch: Bool { requestedLanguage != language }

  func prepareForRelaunch() {
    lock.withLock { preferences.set([storedRequestedLanguage.rawValue], forKey: "AppleLanguages") }
  }

  private func persist(_ language: InterfaceLanguage) {
    preferences.set(language.rawValue, forKey: Self.preferenceKey)
    preferences.set([language.rawValue], forKey: "AppleLanguages")
  }

  var language: InterfaceLanguage {
    get {
      access(keyPath: \.language)
      return lock.withLock { storedLanguage }
    }
    set {
      withMutation(keyPath: \.language) {
        lock.withLock {
          storedLanguage = newValue
          storedRequestedLanguage = newValue
          persist(newValue)
        }
      }
    }
  }
}

/// Keep interpolated values separate: book names and note text are never used
/// as lookup keys or translated. Numbered tokens allow translated word order.
struct InterfaceText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  let key: String
  let arguments: [String]
  init(stringLiteral value: String) { key = value; arguments = [] }
  init(stringInterpolation: StringInterpolation) {
    key = stringInterpolation.key; arguments = stringInterpolation.arguments
  }
  struct StringInterpolation: StringInterpolationProtocol {
    var key = ""
    var arguments: [String] = []
    init(literalCapacity: Int, interpolationCount: Int) {
      key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount)
    }
    mutating func appendLiteral(_ literal: String) { key += literal }
    mutating func appendInterpolation<T>(_ value: T) {
      key += "{\(arguments.count)}"; arguments.append(String(describing: value))
    }
  }
}

enum L10n {
  static var locale: Locale { InterfaceLanguagePreferences.shared.language.locale }
  static var resourceBundle: Bundle {
    #if SWIFT_PACKAGE
    Bundle.module
    #else
    Bundle.main
    #endif
  }
  private static let bundles: [InterfaceLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
    InterfaceLanguage.allCases.compactMap { language in
      resourceBundle.url(forResource: language.rawValue, withExtension: "lproj")
        .flatMap(Bundle.init(url:)).map { (language, $0) }
    })

  static func tr(_ text: InterfaceText) -> String {
    render(text, language: InterfaceLanguagePreferences.shared.language)
  }
  static func render(_ text: InterfaceText, language: InterfaceLanguage) -> String {
    let template = bundles[language]?.localizedString(forKey: text.key, value: text.key, table: nil) ?? text.key
    // Match tokens in the template once; braces inside an argument remain literal.
    let pattern = /\{([0-9]+)\}/
    var output = "", cursor = template.startIndex
    for match in template.matches(of: pattern) {
      output += template[cursor..<match.range.lowerBound]
      if let index = Int(match.1), text.arguments.indices.contains(index) { output += text.arguments[index] }
      else { output += match.0 }
      cursor = match.range.upperBound
    }
    output += template[cursor...]
    return output
  }
}
