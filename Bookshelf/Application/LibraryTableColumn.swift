import Foundation

/// Stable identifiers keep saved columns independent of translated labels or their default order.
enum LibraryTableColumn: String, CaseIterable, Identifiable {
  case title, subtitle, author, publisher, publicationDate
  case translator, bookType, publicationYear, isbn, language, pageCount, addedAt, updatedAt
  var id: String { rawValue }
  var title: String { L10n.tr(titleKey) }
  private var titleKey: InterfaceText {
    switch self {
    case .title: "标题"; case .subtitle: "副标题"; case .author: "作者"; case .translator: "译者"
    case .bookType: "条目类型"; case .publisher: "出版社"; case .publicationDate: "出版日期"
    case .publicationYear: "出版年份"; case .isbn: "ISBN"; case .language: "语言"
    case .pageCount: "页数"
    case .addedAt: "添加日期"; case .updatedAt: "修改日期"
    }
  }
  /// SwiftUI may retain a native header in the previous interface language.
  static func matchingHeaderTitle(_ title: String) -> Self? {
    allCases.first { column in
      InterfaceLanguage.allCases.contains { L10n.render(column.titleKey, language: $0) == title }
    }
  }
  var comparator: KeyPathComparator<Book> {
    switch self {
    case .title: KeyPathComparator(\Book.title)
    case .subtitle: KeyPathComparator(\Book.subtitleSortText)
    case .author: KeyPathComparator(\Book.authorDisplayName)
    case .translator: KeyPathComparator(\Book.translatorSortText)
    case .bookType: KeyPathComparator(\Book.itemTypeSortText)
    case .publisher: KeyPathComparator(\Book.publisherSortText)
    case .publicationDate: KeyPathComparator(\Book.publicationSortText)
    case .publicationYear: KeyPathComparator(\Book.publicationYearSortValue)
    case .isbn: KeyPathComparator(\Book.isbnSortText)
    case .language: KeyPathComparator(\Book.languageSortText)
    case .pageCount: KeyPathComparator(\Book.pageCountSortValue)
    case .addedAt: KeyPathComparator(\Book.addedAt)
    case .updatedAt: KeyPathComparator(\Book.updatedAt)
    }
  }
  func text(for row: LibraryItemRow) -> String {
    if self == .title { return row.title }
    if self == .addedAt { return (row.book?.addedAt ?? row.note?.createdAt)?.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(L10n.locale)) ?? "" }
    if self == .updatedAt { return (row.book?.updatedAt ?? row.note?.updatedAt)?.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(L10n.locale)) ?? "" }
    if self == .bookType, row.note != nil { return L10n.tr("笔记") }
    guard let book = row.book else { return "" }
    switch self {
    case .title: return book.title
    case .subtitle: return book.subtitleSortText
    case .author: return book.authorDisplayName
    case .translator: return book.translatorSortText
    case .bookType: return book.itemTypeSortText
    case .publisher: return book.publisherSortText
    case .publicationDate: return book.publicationSortText
    case .publicationYear: return BookSearchRule.publicationYear(book.publicationDate).map(String.init) ?? ""
    case .isbn: return book.isbnSortText
    case .language: return book.languageSortText
    case .pageCount: return book.pageCount.map(String.init) ?? ""
    case .addedAt, .updatedAt: return ""
    }
  }
}

extension Book {
  var subtitleSortText: String { subtitle ?? "" }
  var publicationSortText: String { publicationDate ?? "" }
  var publisherSortText: String { publisher ?? "" }
  var translatorSortText: String { translators.map(\.name).joined(separator: "、") }
  var itemTypeSortText: String { bookType?.title ?? "" }
  var publicationYearSortValue: Int { BookSearchRule.publicationYear(publicationDate) ?? -1 }
  var isbnSortText: String { isbn13 ?? isbn10 ?? "" }
  var languageSortText: String { languageCode ?? "" }
  var pageCountSortValue: Int { pageCount ?? -1 }
}
