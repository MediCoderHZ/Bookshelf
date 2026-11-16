import SwiftData
import SwiftUI

struct PublisherMetadataField: View {
  @Query(filter: #Predicate<Book> { $0.deletedAt == nil && $0.publisher != nil }) private var books: [Book]
  let book: Book

  var body: some View {
    let usages = books.compactMap(PublisherUsage.init)
    InlineBookMetadataField(book: book, field: .publisher,
      suggestions: { PublisherSuggestions.matches($0, usages: usages) })
  }
}

/// Uses the inspector's catalog and native completion, but only edits the
/// sheet's draft. The enclosing form saves the whole book in one operation.
struct DraftPublisherMetadataField: View {
  @Query(filter: #Predicate<Book> { $0.deletedAt == nil && $0.publisher != nil }) private var books: [Book]
  @Binding var value: String
  @State private var editingBaseline = ""

  var body: some View {
    let usages = books.compactMap(PublisherUsage.init)
    MetadataSuggestionInput(
      input: NativeBookMetadataField(value: value, label: L10n.tr("出版社"), multiline: false,
        focusToken: nil, onFocus: {},
        onBegin: { editingBaseline = value },
        onChange: { value = $0 },
        onCommit: {
          value = value.trimmingCharacters(in: .whitespacesAndNewlines)
          editingBaseline = value
          return true
        },
        onCancel: { value = editingBaseline; return value },
        currentValue: { value }),
      suggestions: PublisherSuggestions.matches(value, usages: usages),
      noun: L10n.tr("出版社"), systemImage: "building.2")
  }
}
