import AppKit
import Foundation
import Observation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class InterfaceLanguageTests: XCTestCase {
  private func preferences() -> UserDefaults {
    let suite = "Bookshelf.LanguageTests." + UUID().uuidString
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    return UserDefaults(suiteName: suite)!
  }
  private func withEnglish(_ action: () throws -> Void) rethrows {
    let previous = InterfaceLanguagePreferences.shared.language
    defer { InterfaceLanguagePreferences.shared.language = previous }
    InterfaceLanguagePreferences.shared.language = .english
    try action()
  }

  func testPreferenceDefaultsToChineseAndSurvivesRestart() {
    let defaults = preferences(), settings = InterfaceLanguagePreferences(preferences: defaults)
    XCTAssertEqual(settings.language, .chinese)
    settings.language = .english
    XCTAssertEqual(InterfaceLanguagePreferences(preferences: defaults).language, .english)
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
    settings.language = .chinese
    XCTAssertEqual(InterfaceLanguagePreferences(preferences: defaults).language, .chinese)
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
    defaults.set("unsupported", forKey: InterfaceLanguagePreferences.preferenceKey)
    XCTAssertEqual(InterfaceLanguagePreferences(preferences: defaults).language, .chinese)
  }

  func testLanguageChangeInvalidatesObservedTextWithoutRecreatingState() {
    let defaults = preferences(), settings = InterfaceLanguagePreferences(preferences: defaults)
    let changed = expectation(description: "Language observation invalidates the interface")
    withObservationTracking { _ = settings.language } onChange: { changed.fulfill() }
    settings.language = .english
    wait(for: [changed], timeout: 1)
  }

  func testRequestedLanguageDoesNotPartiallySwitchTheRunningProcess() {
    let defaults = preferences()
    defaults.set(["zh-Hans"], forKey: "AppleLanguages")
    let settings = InterfaceLanguagePreferences(preferences: defaults, launchLanguage: .chinese)
    settings.requestedLanguage = .english
    XCTAssertEqual(settings.language, .chinese)
    XCTAssertEqual(settings.requestedLanguage, .english)
    XCTAssertTrue(settings.requiresRelaunch)
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
    settings.prepareForRelaunch()
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
    let reopened = InterfaceLanguagePreferences(preferences: defaults, launchLanguage: .english)
    XCTAssertEqual(reopened.language, .english)
    XCTAssertFalse(reopened.requiresRelaunch)
  }

  func testLanguageChangeCanBeCancelledAndFirstLaunchMatchesNativeLanguage() {
    let defaults = preferences()
    let settings = InterfaceLanguagePreferences(preferences: defaults, launchLanguage: .english)
    XCTAssertEqual(settings.language, .english)
    XCTAssertEqual(settings.requestedLanguage, .english)
    settings.requestedLanguage = .chinese
    settings.requestedLanguage = settings.language
    XCTAssertFalse(settings.requiresRelaunch)
    settings.prepareForRelaunch()
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
  }

  func testNativeApplicationNamesAndSettingsTitleAreFullyLocalized() throws {
    for (language, name, title) in [(InterfaceLanguage.chinese, "书架", "书架设置"), (.english, "Bookshelf", "Bookshelf Settings")] {
      let url = try XCTUnwrap(L10n.resourceBundle.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: language.rawValue))
      let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
      XCTAssertEqual(info["CFBundleName"], name)
      XCTAssertEqual(info["CFBundleDisplayName"], name)
      XCTAssertEqual(L10n.render("书架设置", language: language), title)
    }
  }

  func testUndoLabelsDoNotInheritSystemLanguage() {
    let manager = UndoManager()
    let previous = InterfaceLanguagePreferences.shared.language
    defer { InterfaceLanguagePreferences.shared.language = previous }
    InterfaceLanguagePreferences.shared.language = .chinese
    XCTAssertEqual(LibraryUndoLabel.title(manager), "撤销")
    XCTAssertEqual(LibraryUndoLabel.title(manager, redo: true), "重做")
    InterfaceLanguagePreferences.shared.language = .english
    XCTAssertEqual(LibraryUndoLabel.title(manager), "Undo")
    XCTAssertEqual(LibraryUndoLabel.title(manager, redo: true), "Redo")
  }

  func testBuiltInOriginLabelsTranslateWithoutChangingStoredData() throws {
    let origin = MetadataFieldOrigin(name: "手动编辑", url: nil, retrievedAt: nil)
    let before = try JSONEncoder().encode(origin)
    try withEnglish {
      XCTAssertEqual(origin.displayName, "Manual edit")
      XCTAssertEqual(MetadataFieldOrigin.displayName(for: "RIS 文件导入"), "RIS file import")
      XCTAssertEqual(MetadataFieldOrigin.displayName(for: "我的自定义来源"), "我的自定义来源")
      XCTAssertEqual(try JSONEncoder().encode(origin), before)
    }
  }

  func testBothResourceCatalogsHaveCompleteMatchingKeysAndTokens() throws {
    func catalog(_ language: InterfaceLanguage) throws -> [String: String] {
      let url = try XCTUnwrap(L10n.resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language.rawValue))
      return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }
    let chinese = try catalog(.chinese), english = try catalog(.english)
    XCTAssertGreaterThan(chinese.count, 800)
    XCTAssertEqual(Set(chinese.keys), Set(english.keys))
    for (key, value) in chinese {
      let translated = try XCTUnwrap(english[key])
      XCTAssertFalse(translated.isEmpty, key)
      XCTAssertEqual(value.matches(of: /\{[0-9]+\}/).map { String($0.0) }.sorted(),
        translated.matches(of: /\{[0-9]+\}/).map { String($0.0) }.sorted(), key)
      XCTAssertNil(translated.range(of: "[\\p{Han}]", options: .regularExpression), key)
    }
  }

  func testEnglishAndChineseLabelsAndInterpolatedCounts() {
    XCTAssertEqual(L10n.render("全部书籍", language: .chinese), "全部书籍")
    XCTAssertEqual(L10n.render("全部书籍", language: .english), "All Books")
    XCTAssertEqual(L10n.render("此视图中有 \(12) 个条目", language: .english), "12 items in this view")
    XCTAssertEqual(L10n.render("此视图中有 \(12) 个条目", language: .chinese), "此视图中有 12 个条目")
    XCTAssertEqual(L10n.render("一个缺少翻译的提示", language: .english), "一个缺少翻译的提示")
  }

  func testInterpolationReordersArgumentsWithoutTranslatingOrReinterpretingContent() {
    let name = "全部书籍 {1} 100% %@ \"quote\"\n中文"
    XCTAssertEqual(L10n.render("同步更新使用“\(name)”的 \(2) 本书和 \(3) 条笔记。", language: .english),
      "Update the 2 books and 3 notes using “\(name)”.")
  }

  func testTranslatedLabelsDoNotChangeStoredIdentifiersOrLegacyPanelDecoding() throws {
    try withEnglish {
      XCTAssertEqual(BookType.chineseOriginal.title, "Chinese Original")
      XCTAssertEqual(BookType.chineseOriginal.rawValue, "chineseOriginal")
      XCTAssertEqual(BookType.chineseOriginal.legacyPresetName, "中文原版书")
      XCTAssertEqual(InspectorPanel.collections.title, "Collections")
      XCTAssertEqual(InspectorPanel.collections.rawValue, "文件夹")
      for name in ["文件夹", "书库与书单", "书库与文件夹"] {
        let encoded = try JSONEncoder().encode(name)
        XCTAssertEqual(try JSONDecoder().decode(InspectorPanel.self, from: encoded), .collections)
      }
      XCTAssertEqual(LibrarySearchScope.fieldsAndTags.rawValue, "fieldsAndTags")
    }
  }

  func testSwitchingLanguagePreservesBooksNotesCollectionsAndSearchValues() throws {
    let container = try LibraryDatabase.open(inMemory: true), context = container.mainContext
    let book = Book(title: "全部书籍 {0}"); book.publisher = "出版社"; book.bookTypeRaw = "chineseOriginal"
    var note = NoteRecord(title: "新笔记", parentBookID: book.id); note.body = "# English and 中文\n{1} 100%"
    let collection = ManualCollectionRecord(name: "全部书籍")
    try LibraryRepository.apply([BookArchive(book: book)], manualCollections: [collection], notes: [note], into: context)
    let before = try LibraryBackupService.decode(LibraryBackupService.exportData(from: context))
    let search = BookSearchRule(field: .bookType, comparison: .equals, value: "chineseOriginal")
    try withEnglish {
      let after = try LibraryBackupService.decode(LibraryBackupService.exportData(from: context))
      XCTAssertEqual(before.books, after.books)
      XCTAssertEqual(before.libraryNotes, after.libraryNotes)
      XCTAssertEqual(before.collections, after.collections)
      XCTAssertEqual(search.value, "chineseOriginal")
      XCTAssertTrue(search.matches(book))
      XCTAssertFalse(context.hasChanges)
    }
  }

  func testCachedTranslatorAndErrorDescriptionsFollowLanguageChoice() {
    let translator = RISTranslator()
    withEnglish {
      XCTAssertEqual(translator.descriptor.name, "RIS Bibliography")
      XCTAssertEqual(AutomaticBackupKind.manual.title, "Manual backup")
      XCTAssertEqual(BookMetadataEditError.emptyTitle.errorDescription, "The title cannot be empty.")
    }
  }

  func testHistoricalPresetMigrationUsesStableNamesInEnglish() throws {
    let container = try LibraryDatabase.open(inMemory: true), context = container.mainContext
    let defaults = preferences()
    let query = AdvancedBookQuery(rules: [BookSearchRule(field: .bookType, comparison: .equals, value: "chineseOriginal")])
    _ = try SmartCollectionService.save(name: "中文原版书", query: query, context: context, undoManager: nil)
    let kept = try SmartCollectionService.save(name: "Chinese Original", query: query, context: context, undoManager: nil)
    let storeID = container.configurations.map { $0.url.standardizedFileURL.absoluteString }.sorted().joined(separator: "|")
    defaults.set(true, forKey: "bookTypeSmartCollectionsInstalled.v1." + storeID)
    try withEnglish {
      try SmartCollectionService.retireBookTypeDefaults(in: context, preferences: defaults)
      XCTAssertEqual(Set(try SmartCollectionService.snapshots(in: context).keys), [kept])
    }
  }

  func testCachedNativeHeadersChangeLanguageWithoutReplacingColumnsOrWidths() {
    let table = NSTableView()
    let title = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("stable-title"))
    title.title = "标题"; title.width = 271
    let publisher = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("stable-publisher"))
    publisher.title = "出版社"; publisher.width = 167; publisher.isHidden = true
    table.addTableColumn(title); table.addTableColumn(publisher)
    withEnglish {
      LibraryColumnAutoFit.localizeHeaders(in: table)
      XCTAssertEqual(title.title, "Title"); XCTAssertEqual(publisher.title, "Publisher")
      XCTAssertTrue(table.tableColumns[0] === title)
      XCTAssertEqual(title.identifier.rawValue, "stable-title")
      XCTAssertEqual(title.width, 271); XCTAssertEqual(publisher.width, 167)
      XCTAssertTrue(publisher.isHidden)
      XCTAssertEqual(LibraryTableColumn.matchingHeaderTitle("出版日期"), .publicationDate)
      XCTAssertEqual(LibraryTableColumn.matchingHeaderTitle("Publication Date"), .publicationDate)
    }
    let previous = InterfaceLanguagePreferences.shared.language
    defer { InterfaceLanguagePreferences.shared.language = previous }
    InterfaceLanguagePreferences.shared.language = .chinese
    LibraryColumnAutoFit.localizeHeaders(in: table)
    XCTAssertEqual(title.title, "标题"); XCTAssertEqual(publisher.title, "出版社")
  }
}
