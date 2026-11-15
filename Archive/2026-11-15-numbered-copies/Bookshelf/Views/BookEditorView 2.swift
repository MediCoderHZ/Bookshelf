import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BookEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(\.libraryUndoManager) private var undoManager
  @Query(sort: \Book.addedAt, order: .reverse) private var allBooks: [Book]
  @Query(sort: \BookCollection.name) private var storedCollections: [BookCollection]
  private var allCollections: [BookCollection] { storedCollections.filter { !$0.isSmart } }

  let book: Book?
  var initialCollectionID: UUID? = nil
  var startWithSearch = false
  var startWithWebImport = false

  @State private var bookType: BookType? = .chineseOriginal
  @State private var hasSelectedBookType = false
  @State private var originalLanguageCode = ""
  @State private var title = ""
  @State private var subtitle = ""
  @State private var originalTitle = ""
  @State private var authors = ""
  @State private var translators = ""
  @State private var isbn = ""
  @State private var publisher = ""
  @State private var publicationDate = ""
  @State private var edition = ""
  @State private var pageCount: Int?
  @State private var languageCode = ""
  @State private var bookDescription = ""
  @State private var isFavorite = false
  @State private var notes = ""
  @State private var tags = ""
  @State private var collectionName = ""
  @State private var selectedCollectionIDs = Set<UUID>()
  @State private var hasLoaded = false
  @State private var pendingCoverData: Data?
  @State private var isChoosingCover = false
  @State private var isShowingMetadataSearch = false
  @State private var isShowingWebImport = false
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
      Form {
        Section("在线检索") {
          Button {
            isShowingMetadataSearch = true
          } label: {
            Label("按书名或 ISBN 搜索元信息…", systemImage: "magnifyingglass")
          }

          Text("选择搜索结果后，逐字段核对新旧值；默认仅补全空白，再填入编辑页。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button {
            isShowingWebImport = true
          } label: {
            Label("从网页提取元信息…", systemImage: "link")
          }
        }

        Section("封面") {
          HStack(alignment: .top, spacing: 18) {
            coverPreview
              .frame(width: 108, height: 151)

            VStack(alignment: .leading, spacing: 10) {
              Button("选择图片…") {
                isChoosingCover = true
              }

              if pendingCoverData != nil || book?.coverFileName != nil {
                Button("移除封面", role: .destructive) {
                  pendingCoverData = Data()
                }
              }

              Text("图片会复制到应用的沙盒目录，不依赖原始文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        Section("基本信息") {
          LabeledContent("条目类型") {
            BookTypePicker(selection: Binding(get: { bookType }, set: {
              bookType = $0; hasSelectedBookType = true
            }))
          }
          TextField("书名", text: $title)
          TextField("副标题", text: $subtitle)
          if BookMetadataLayout.allows(.originalTitle, type: bookType) {
            TextField("原书名（可选）", text: $originalTitle)
          }
          if BookMetadataLayout.allows(.originalLanguage, type: bookType) {
            TextField("原作语言（可选）", text: $originalLanguageCode)
          }
          TextField("作者（用逗号或顿号分隔）", text: $authors)
          if BookMetadataLayout.allows(.translators, type: bookType) {
            TextField("译者（用逗号或顿号分隔）", text: $translators)
          }
          TextField("简介", text: $bookDescription, axis: .vertical)
            .lineLimit(3...8)
        }

        Section("出版信息") {
          TextField("ISBN-10 或 ISBN-13", text: $isbn)
          TextField("出版社", text: $publisher)
          TextField("出版日期，例如 2025-03", text: $publicationDate)
          TextField("版次", text: $edition)
          TextField("页数", value: $pageCount, format: .number)
          TextField("语言代码", text: $languageCode)
        }

        Section("个人管理") {
          Toggle("收藏", isOn: $isFavorite)
          TextField("标签（用逗号或顿号分隔）", text: $tags)
          ForEach(allCollections) { collection in
            Toggle(
              CollectionTree.path(collection.id, in: allCollections.map(ManualCollectionRecord.init)),
              isOn: Binding(
                get: { selectedCollectionIDs.contains(collection.id) },
                set: { included in
                  if included {
                    selectedCollectionIDs.insert(collection.id)
                  } else {
                    selectedCollectionIDs.remove(collection.id)
                  }
                }
              ))
          }
          TextField("新建并加入书单（可选）", text: $collectionName)
          TextField("个人备注", text: $notes, axis: .vertical)
            .lineLimit(3...8)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(book == nil ? "添加书籍" : "编辑书籍")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("保存") { attemptSave() }
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .fileImporter(
      isPresented: $isChoosingCover,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      do {
        guard let url = try result.get().first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        pendingCoverData = try Data(contentsOf: url)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
    .sheet(isPresented: $isShowingMetadataSearch, onDismiss: presentMetadataReview) {
      BookMetadataSearchView(initialQuery: isbn.nilIfBlank ?? title) { result, cover in
        pendingMetadata = MetadataUpdateProposal(current: draftRecord(), incoming: BookArchive(metadata: result, cover: cover))
      }
    }
    .sheet(isPresented: $isShowingWebImport, onDismiss: presentMetadataReview) {
      WebMetadataImportView { result, cover in
        pendingMetadata = MetadataUpdateProposal(current: draftRecord(), incoming: BookArchive(metadata: result, cover: cover))
      }
    }
    .sheet(item: $metadataProposal) { proposal in
      MetadataUpdateView(proposal: proposal) { fields in applyMetadata(proposal, fields: fields) }
    }
    .alert(
      "书籍信息",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "发生未知错误")
    }
    .confirmationDialog(
      "可能已经存在这本书",
      isPresented: Binding(
        get: { duplicateMessage != nil },
        set: { if !$0 { duplicateMessage = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("仍然保存") {
        duplicateMessage = nil
        save()
      }
      Button("返回修改", role: .cancel) {
        duplicateMessage = nil
      }
    } message: {
      Text(duplicateMessage ?? "")
    }
    .onAppear(perform: loadBook)
  }

  @ViewBuilder
  private var coverPreview: some View {
    if let pendingCoverData,
      !pendingCoverData.isEmpty,
      let image = NSImage(data: pendingCoverData)
    {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
        .clipShape(RoundedRectangle(cornerRadius: 5))
    } else if pendingCoverData == nil, let book {
      CoverImageView(book: book)
    } else {
      RoundedRectangle(cornerRadius: 5)
        .fill(.quaternary)
        .overlay {
          Image(systemName: "photo")
            .font(.title)
            .foregroundStyle(.secondary)
        }
    }
  }

  private func loadBook() {
    guard !hasLoaded else { return }
    hasLoaded = true
    defer { sourceBaseline = draftRecord() }
    isShowingMetadataSearch = startWithSearch
    isShowingWebImport = startWithWebImport
    if let initialCollectionID { selectedCollectionIDs.insert(initialCollectionID) }
    guard let book else {
      if startWithSearch || startWithWebImport { bookType = nil }
      return
    }
    bookType = book.bookType
    originalLanguageCode = book.originalLanguageCode ?? ""
    editingBaseline = BookArchive(book: book)
    title = book.title
    subtitle = book.subtitle ?? ""
    originalTitle = book.originalTitle ?? ""
    authors = book.authors.map(\.name).joined(separator: "、")
    translators = book.translators.map(\.name).joined(separator: "、")
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
    isFavorite = book.isFavorite
    notes = book.notes ?? ""
    tags = book.tagLinks.compactMap(\.tag?.name).joined(separator: "、")
    selectedCollectionIDs = Set(book.collectionItems.compactMap(\.collection?.id))
  }

  private func presentMetadataReview() {
    metadataProposal = pendingMetadata
    pendingMetadata = nil
  }

  private func draftRecord() -> BookArchive {
    var record = editingBaseline ?? BookArchive(book: Book(title: title))
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
    record.contributors += MetadataNormalizer.contributorNames(from: authors).enumerated().map {
      ContributorArchive(name: $0.element, roleRaw: "author", displayOrder: $0.offset)
    }
    record.contributors += MetadataNormalizer.contributorNames(from: translators).enumerated().map {
      ContributorArchive(name: $0.element, roleRaw: "translator", displayOrder: $0.offset)
    }
    record.metadataSourceName = metadataSourceName
    record.metadataSourceURL = metadataSourceURL
    record.metadataRetrievedAt = metadataRetrievedAt
    record.metadataFieldSourcesJSON = metadataFieldSourcesJSON
    if let pendingCoverData { record.coverData = pendingCoverData.isEmpty ? nil : pendingCoverData }
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
    authors = BookField.authors.value(in: record)
    translators = BookField.translators.value(in: record)
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
    if fields.contains(.cover) { pendingCoverData = proposal.incoming.coverData }
    sourceBaseline = record
  }

  private func attemptSave() {
    let authorNames = MetadataNormalizer.contributorNames(from: authors)
    if let match = DuplicateDetector.firstMatch(
      title: title,
      isbn: isbn,
      authorNames: authorNames,
      excluding: book?.id,
      in: allBooks
    ) {
      duplicateMessage = "\(match.reason)。你可以返回修改，或确认仍然保存为另一条记录。"
      return
    }

    save()
  }

  private func save() {
    do {
      var record = draftRecord()
      record.isFavorite = isFavorite
      record.notes = notes.nilIfBlank
      record.tags = MetadataNormalizer.contributorNames(from: tags).sorted()
      record.collections = allCollections.filter { !$0.isSmart && selectedCollectionIDs.contains($0.id) }.map(\.name)
      if let name = collectionName.nilIfBlank {
        let key = MetadataNormalizer.normalizedName(name)
        let existing = allCollections.first { !$0.isSmart && $0.normalizedName == key }
        let resolved = existing?.name ?? name
        if !record.collections.contains(resolved) { record.collections.append(resolved) }
      }
      record.collections.sort()
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
