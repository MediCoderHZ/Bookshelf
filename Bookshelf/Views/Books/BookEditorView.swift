import AppKit
import SwiftData
import SwiftUI

struct BookEditorView: View {
  @Environment(\.libraryDisplay) private var display
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(\.libraryUndoManager) private var undoManager
  @Query(sort: \Book.addedAt, order: .reverse) private var allBooks: [Book]
  @Query(sort: \BookCollection.name) private var storedCollections: [BookCollection]

  let book: Book?
  var initialCollectionID: UUID? = nil
  var startWithSearch = false

  @State private var bookType: BookType? = .chineseOriginal
  @State private var hasSelectedBookType = false
  @State private var originalLanguageCode = ""
  @State private var title = ""
  @State private var subtitle = ""
  @State private var originalTitle = ""
  @State private var authors = ContributorListDraft()
  @State private var translators = ContributorListDraft()
  @State private var isbn = ""
  @State private var publisher = ""
  @State private var publicationDate = ""
  @State private var edition = ""
  @State private var pageCount: Int?
  @State private var languageCode = ""
  @State private var bookDescription = ""
  @State private var hasLoaded = false
  @State private var isShowingMetadataSearch = false
  @State private var metadataSourceName: String?
  @State private var metadataSourceURL: String?
  @State private var metadataRetrievedAt: Date?
  @State private var metadataFieldSourcesJSON: String?
  @State private var pendingMetadata: MetadataUpdateProposal?
  @State private var metadataProposal: MetadataUpdateProposal?
  @State private var draftID = UUID()
  @State private var sourceBaseline: BookArchive?
  @State private var editingBaseline: BookArchive?
  @State private var errorMessage: String?
  @State private var duplicateMessage: String?

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (book != nil || bookType != nil)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Button {
            isShowingMetadataSearch = true
          } label: {
            Label(L10n.tr("按书名或 ISBN 搜索元信息…"), systemImage: "magnifyingglass")
          }

          VStack(alignment: .leading, spacing: display.fieldSpacing) {
            metadataRow(L10n.tr("条目类型")) {
              BookTypePicker(selection: Binding(get: { bookType }, set: {
                NSApp.keyWindow?.makeFirstResponder(nil)
                bookType = $0; hasSelectedBookType = true
              }))
            }
            metadataTextField(L10n.tr("标题"), text: $title)
            metadataTextField(L10n.tr("副标题"), text: $subtitle)
            if BookMetadataLayout.allows(.originalTitle, type: bookType) {
              metadataTextField(L10n.tr("原书名"), text: $originalTitle)
            }
            if BookMetadataLayout.allows(.originalLanguage, type: bookType) {
              metadataTextField(L10n.tr("原作语言"), text: $originalLanguageCode)
            }
            DraftContributorListField(draft: $authors, field: .authors)
            if BookMetadataLayout.allows(.translators, type: bookType) {
              DraftContributorListField(draft: $translators, field: .translators)
            }
            metadataRow(L10n.tr("出版社")) {
              DraftPublisherMetadataField(value: $publisher)
            }
            metadataTextField(L10n.tr("出版日期"), text: $publicationDate)
            metadataTextField("ISBN", text: $isbn)
            metadataTextField(L10n.tr("版次"), text: $edition)
            metadataRow(L10n.tr("页数")) {
              TextField("", value: $pageCount, format: .number)
                .accessibilityLabel(L10n.tr("页数"))
            }
            metadataTextField(L10n.tr("语言"), text: $languageCode)
          }
        }
        .font(display.font)
        .textFieldStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle(book == nil ? L10n.tr("添加书籍") : L10n.tr("编辑书籍"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.tr("取消")) { dismiss() }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.tr("保存")) { attemptSave() }
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
      }
    }

    .sheet(isPresented: $isShowingMetadataSearch, onDismiss: presentMetadataReview) {
      BookMetadataSearchView(initialQuery: isbn.nilIfBlank ?? title) { result in
        pendingMetadata = MetadataUpdateProposal(current: draftRecord(), incoming: BookArchive(metadata: result))
      }
    }
    .sheet(item: $metadataProposal) { proposal in
      MetadataUpdateView(proposal: proposal) { fields in applyMetadata(proposal, fields: fields) }
    }
    .alert(
      L10n.tr("书籍信息"),
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button(L10n.tr("好"), role: .cancel) {}
    } message: {
      Text(errorMessage ?? L10n.tr("发生未知错误"))
    }
    .confirmationDialog(
      L10n.tr("可能已经存在这本书"),
      isPresented: Binding(
        get: { duplicateMessage != nil },
        set: { if !$0 { duplicateMessage = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(L10n.tr("仍然保存")) {
        duplicateMessage = nil
        save()
      }
      Button(L10n.tr("返回修改"), role: .cancel) {
        duplicateMessage = nil
      }
    } message: {
      Text(duplicateMessage ?? "")
    }
    .onAppear(perform: loadBook)
  }

  private func metadataRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: display.metadataLabelWidth, alignment: .trailing)
      content()
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
    }
  }

  private func metadataTextField(_ title: String, text: Binding<String>) -> some View {
    metadataRow(title) {
      TextField("", text: text).accessibilityLabel(title)
    }
  }

  private func loadBook() {
    guard !hasLoaded else { return }
    hasLoaded = true
    defer { sourceBaseline = draftRecord() }
    isShowingMetadataSearch = startWithSearch
    guard let book else {
      if startWithSearch { bookType = nil }
      return
    }
    bookType = book.bookType
    originalLanguageCode = book.originalLanguageCode ?? ""
    editingBaseline = BookArchive(book: book)
    title = book.title
    subtitle = book.subtitle ?? ""
    originalTitle = book.originalTitle ?? ""
    authors = ContributorListDraft(people: editingBaseline?.contributors.filter { $0.roleRaw == "author" } ?? [])
    translators = ContributorListDraft(people: editingBaseline?.contributors.filter { $0.roleRaw == "translator" } ?? [])
    isbn = book.isbn13 ?? book.isbn10 ?? ""
    publisher = book.publisher ?? ""
    publicationDate = book.publicationDate ?? ""
    edition = book.edition ?? ""
    pageCount = book.pageCount
    languageCode = book.languageCode ?? ""
    bookDescription = book.bookDescription ?? ""
    metadataSourceName = book.metadataSourceName
    metadataSourceURL = book.metadataSourceURL
    metadataRetrievedAt = book.metadataRetrievedAt
    metadataFieldSourcesJSON = book.metadataFieldSourcesJSON
  }

  private func presentMetadataReview() {
    metadataProposal = pendingMetadata
    pendingMetadata = nil
  }

  private func draftRecord() -> BookArchive {
    // Organization and notes are not edited in this form; retain their exact
    // baseline values, including tag names containing punctuation.
    var record = editingBaseline ?? BookArchive(book: Book(title: title))
    if book == nil, let collection = storedCollections.first(where: { $0.id == initialCollectionID && !$0.isSmart }) {
      record.collections = [collection.name]
    }
    record.id = book?.id ?? draftID
    record.title = title
    record.bookTypeRaw = bookType?.rawValue
    record.originalLanguageCode = originalLanguageCode.nilIfBlank
    record.subtitle = subtitle.nilIfBlank
    record.originalTitle = originalTitle.nilIfBlank
    record.publisher = publisher.nilIfBlank
    record.publicationDate = publicationDate.nilIfBlank
    record.edition = edition.nilIfBlank
    record.pageCount = pageCount
    record.languageCode = languageCode.nilIfBlank
    record.bookDescription = bookDescription.nilIfBlank
    record.isbn10 = ISBN.normalized(isbn).flatMap { $0.count == 10 ? $0 : nil }
    record.isbn13 = ISBN.normalized(isbn).flatMap { $0.count == 13 ? $0 : nil }
    record.contributors.removeAll { ["author", "translator"].contains($0.roleRaw) }
    record.contributors += authors.contributors(role: "author")
    record.contributors += translators.contributors(role: "translator")
    record.metadataSourceName = metadataSourceName
    record.metadataSourceURL = metadataSourceURL
    record.metadataRetrievedAt = metadataRetrievedAt
    record.metadataFieldSourcesJSON = metadataFieldSourcesJSON
    if let baseline = sourceBaseline {
      record = BookRecordMerge.markingManualChanges(record, comparedTo: baseline)
    }
    return record
  }

  private func applyMetadata(_ proposal: MetadataUpdateProposal, fields: Set<BookField>) {
    let record = BookRecordMerge.applyingMetadata(proposal.incoming, to: proposal.current, fields: fields)
    if book == nil && !hasSelectedBookType {
      bookType = proposal.incoming.bookType
    } else { bookType = record.bookType }
    originalLanguageCode = record.originalLanguageCode ?? ""
    title = record.title
    subtitle = record.subtitle ?? ""
    originalTitle = record.originalTitle ?? ""
    authors = ContributorListDraft(people: record.contributors.filter { $0.roleRaw == "author" })
    translators = ContributorListDraft(people: record.contributors.filter { $0.roleRaw == "translator" })
    publisher = record.publisher ?? ""
    publicationDate = record.publicationDate ?? ""
    edition = record.edition ?? ""
    isbn = record.isbn13 ?? record.isbn10 ?? ""
    pageCount = record.pageCount
    languageCode = record.languageCode ?? ""
    bookDescription = record.bookDescription ?? ""
    metadataSourceName = proposal.incoming.metadataSourceName
    metadataSourceURL = proposal.incoming.metadataSourceURL
    metadataRetrievedAt = proposal.incoming.metadataRetrievedAt
    metadataFieldSourcesJSON = record.metadataFieldSourcesJSON
    sourceBaseline = record
  }

  private func attemptSave() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do { try authors.validate(); try translators.validate() }
    catch { errorMessage = error.localizedDescription; return }
    let authorNames = authors.names
    if let match = DuplicateDetector.firstMatch(
      title: title,
      isbn: isbn,
      authorNames: authorNames,
      excluding: book?.id,
      in: allBooks
    ) {
      duplicateMessage = L10n.tr("\(match.reason)。你可以返回修改，或确认仍然保存为另一条记录。")
      return
    }

    save()
  }

  private func save() {
    do {
      try authors.validate(); try translators.validate()
      let record = draftRecord()
      try LibraryCommands(context: modelContext, undoManager: undoManager).save(record, expected: editingBaseline)
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }

}

extension String {
  fileprivate var nilIfBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
