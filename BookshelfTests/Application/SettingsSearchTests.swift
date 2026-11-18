import XCTest
@testable import Bookshelf

final class SettingsSearchTests: XCTestCase {
  func testSearchFindsControlsInEitherLanguage() {
    XCTAssertEqual(SettingsGroup.search("界面语言"), [.appearance])
    XCTAssertEqual(SettingsGroup.search("English"), [.appearance])
    XCTAssertEqual(SettingsGroup.search("backup history"), [.automaticBackup])
    XCTAssertEqual(SettingsGroup.search("许可"), [.about])
    XCTAssertEqual(SettingsGroup.search("隐私"), [.about])
    XCTAssertEqual(SettingsGroup.search("privacy"), [.about])
    XCTAssertEqual(SettingsGroup.search("解析器"), [.translators])
    XCTAssertEqual(SettingsGroup.search("translators").map(\.pane), [.storage])
    XCTAssertEqual(SettingsGroup.search("database integrity"), [.storage])
  }

  func testSearchNormalizesCaseWidthWhitespaceAndCombinesTerms() {
    XCTAssertEqual(SettingsGroup.search("  jSoN \n restore  "), [.restore])
    XCTAssertEqual(SettingsGroup.search("Ｅｎｇｌｉｓｈ"), [.appearance])
    XCTAssertEqual(SettingsGroup.search("界面 language"), [.appearance])
    XCTAssertEqual(SettingsGroup.search("JSON language"), [])
  }

  func testEmptyAndUnmatchedSearchHavePredictableResults() {
    XCTAssertEqual(SettingsGroup.search("  \n"), SettingsGroup.allCases)
    XCTAssertEqual(SettingsGroup.search("missing-setting-12345"), [])
    XCTAssertEqual(SettingsGroup.search("备份与恢复"), SettingsPane.backups.groups)
    for query in ["RIS", "CSV", "书目交换", "导入与导出", "Import and Export", "书库显示", "界面密度", "字号", "Library Display", "density", "font size"] {
      XCTAssertEqual(SettingsGroup.search(query), [], query)
    }
    XCTAssertEqual(SettingsGroup.search("撤销"), [])
    XCTAssertEqual(SettingsGroup.search("software updates"), [])
  }
}
