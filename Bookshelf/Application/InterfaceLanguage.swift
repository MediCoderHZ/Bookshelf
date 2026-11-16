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
  static let shared = InterfaceLanguagePreferences()
  static let preferenceKey = "interfaceLanguage"
  @ObservationIgnored private let preferences: UserDefaults
  @ObservationIgnored private let lock = NSLock()
  @ObservationIgnored private var storedLanguage: InterfaceLanguage

  init(preferences: UserDefaults = .standard) {
    self.preferences = preferences
    storedLanguage = preferences.string(forKey: Self.preferenceKey).flatMap(InterfaceLanguage.init(rawValue:)) ?? .chinese
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
          preferences.set(newValue.rawValue, forKey: Self.preferenceKey)
          // AppKit and Sparkle read their bundle language at process startup.
          preferences.set([newValue.rawValue], forKey: "AppleLanguages")
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
