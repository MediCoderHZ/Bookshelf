import XCTest
@testable import Bookshelf

final class SettingsSearchTests: XCTestCase {
  func testSearchFindsControlsInEitherLanguage() {
    XCTAssertEqual(SettingsGroup.search("界面语言"), [.appearance])
    XCTAssertEqual(SettingsGroup.search("English"), [.appearance])
    XCTAssertEqual(SettingsGroup.search("字号"), [.display])
    XCTAssertEqual(SettingsGroup.search("backup history"), [.automaticBackup])
    XCTAssertEqual(SettingsGroup.search("许可"), [.about])
    XCTAssertEqual(SettingsGroup.search("CSV"), [.exchange, .translators])
  }

  func testSearchNormalizesCaseWidthWhitespaceAndCombinesTerms() {
    XCTAssertEqual(SettingsGroup.search("  jSoN \n restore  "), [.restore])
    XCTAssertEqual(SettingsGroup.search("Ｅｎｇｌｉｓｈ"), [.appearance])
    XCTAssertEqual(SettingsGroup.search("界面 font"), [.display])
    XCTAssertEqual(SettingsGroup.search("JSON language"), [])
  }

  func testEmptyAndUnmatchedSearchHavePredictableResults() {
    XCTAssertEqual(SettingsGroup.search("  \n"), SettingsGroup.allCases)
    XCTAssertEqual(SettingsGroup.search("missing-setting-12345"), [])
    XCTAssertEqual(SettingsGroup.search("备份与恢复"), SettingsPane.backups.groups)
  }
}
