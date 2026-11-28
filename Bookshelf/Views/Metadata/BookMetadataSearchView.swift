import SwiftUI

struct BookMetadataSearchView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(TranslatorStore.self) private var translators
  let onSelect: (BookMetadataSearchResult) -> Void

  @State private var query: String
  @State private var sourceID = "all"
  @State private var batches: [MetadataSearchBatch] = []
  @State private var submittedQuery: BookMetadataQuery?
  @State private var selected: MetadataSearchHit?
  @State private var preview: BookMetadataSearchResult?
  @State private var detailError: String?
  @State private var isSearching = false
  @State private var isResolving = false
  @State private var searchTask: Task<Void, Never>?
  @State private var selectionTask: Task<Void, Never>?
  @State private var generation = UUID()
  @State private var selectionID = UUID()

  init(initialQuery: String, onSelect: @escaping (BookMetadataSearchResult) -> Void) {
    self.onSelect = onSelect
    _query = State(initialValue: initialQuery)
  }

  private var service: MetadataSearchService { MetadataSearchService(catalog: translators.catalog) }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 10) {
            TextField(L10n.tr("输入书名或 ISBN"), text: $query)
              .textFieldStyle(.roundedBorder).onSubmit(startSearch)
              .accessibilityLabel(L10n.tr("书名或 ISBN"))
            Picker(L10n.tr("来源"), selection: $sourceID) {
              Text(L10n.tr("全部已启用来源")).tag("all")
              ForEach(service.sources) { Text(MetadataFieldOrigin.displayName(for: $0.name)).tag($0.id) }
            }.frame(width: 205)
            if isSearching {
              Button(L10n.tr("停止")) { reset() }
            } else {
              Button(L10n.tr("搜索"), action: startSearch)
                .disabled(service.sources.isEmpty || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }
          Text(L10n.tr("搜索会将书名或 ISBN 发送给所选来源。"))
            .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.vertical, 14)
        Divider()
        if batches.isEmpty {
          ContentUnavailableView(service.sources.isEmpty ? L10n.tr("没有已启用的搜索来源") : L10n.tr("按书名或 ISBN 搜索"),
            systemImage: "magnifyingglass")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if batches.allSatisfy({ $0.hits.isEmpty }) {
          resultList
        } else {
          HStack(spacing: 0) {
            resultList.frame(minWidth: 245, idealWidth: 285, maxWidth: 315)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
      .navigationTitle(L10n.tr("搜索书籍元信息"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.tr("取消")) { reset(); dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.tr("核对字段…"), action: apply)
            .disabled(preview == nil || isResolving).keyboardShortcut(.defaultAction)
        }
      }
    }
    .frame(minWidth: 740, idealWidth: 840, minHeight: 480, idealHeight: 560)
    .onChange(of: query) { _, _ in reset() }
    .onChange(of: sourceID) { _, _ in reset() }
    .onChange(of: translators.revision) { _, _ in
      reset()
      if sourceID != "all" && !service.sources.contains(where: { $0.id == sourceID }) { sourceID = "all" }
    }
    .onDisappear { reset() }
  }

  private var resultList: some View {
    List {
      ForEach(batches) { batch in
        Section {
          if batch.isLoading {
            HStack { ProgressView().controlSize(.small); Text(L10n.tr("正在搜索…")) }
          } else if let error = batch.error {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            if let query = submittedQuery, let url = service.searchURL(for: query, source: batch.source) {
              Link(L10n.tr("在浏览器查看搜索结果"), destination: url).font(.caption)
            }
          } else if batch.hits.isEmpty {
            Text(L10n.tr("未找到结果，可尝试其他书名或 ISBN。")).font(.caption).foregroundStyle(.secondary)
          }
          ForEach(batch.hits) { hit in
            Button { select(hit) } label: {
              HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(hit.title).fontWeight(.medium).lineLimit(2)
                  if let subtitle = hit.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                  }
                }
                Spacer(minLength: 0)
                if selected?.id == hit.id {
                  Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 8).padding(.vertical, 6)
              .background(selected?.id == hit.id ? Color.accentColor.opacity(0.15) : .clear,
                in: RoundedRectangle(cornerRadius: 5))
              .contentShape(Rectangle())
            }.buttonStyle(.plain)
              .accessibilityAddTraits(selected?.id == hit.id ? .isSelected : [])
          }
        } header: {
          let source = MetadataFieldOrigin.displayName(for: batch.source.name)
          Text(batch.isLoading ? source : L10n.tr("\(source) · \(batch.hits.count) 项"))
        }
      }
    }.listStyle(.inset)
  }

  @ViewBuilder private var detail: some View {
    if isResolving {
      VStack(spacing: 14) {
        ProgressView()
        Text(L10n.tr("正在读取图书详情…"))
        Button(L10n.tr("停止读取")) { cancelSelection() }
      }
    } else if let book = preview {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 5) {
            Text(book.title).font(.title2.bold()).textSelection(.enabled)
            if let url = book.sourceURL {
              Link(destination: url) {
                HStack(spacing: 4) {
                  Text(MetadataFieldOrigin.displayName(for: book.sourceName))
                  Image(systemName: "arrow.up.right").accessibilityHidden(true)
                }
              }.font(.callout).help(L10n.tr("查看来源网页"))
            } else {
              Text(MetadataFieldOrigin.displayName(for: book.sourceName)).font(.callout).foregroundStyle(.secondary)
            }
          }
          if let warning = MetadataSearchService.isbnNotice(query: submittedQuery, book: book) {
            Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
          }
          Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 10) {
            row(L10n.tr("作者"), book.authors.joined(separator: "、"))
            row(L10n.tr("译者"), book.translators.joined(separator: "、"))
            row(L10n.tr("出版社"), book.publisher)
            row(L10n.tr("出版日期"), book.publicationDate)
            row("ISBN", book.preferredISBN)
            row(L10n.tr("页数"), book.pageCount.map(String.init))
            row(L10n.tr("语言"), book.languageCode)
            row(L10n.tr("原书名"), book.originalTitle)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
      }
    } else if let detailError {
      VStack(spacing: 12) {
        ContentUnavailableView(L10n.tr("暂时无法读取详情"), systemImage: "wifi.exclamationmark", description: Text(detailError))
        if let selected { Button(L10n.tr("重试读取")) { select(selected) } }
        if let url = selected?.candidate?.url { Link(L10n.tr("在浏览器查看此版本"), destination: url) }
      }
    } else {
      ContentUnavailableView(L10n.tr("选择一本书"), systemImage: "book.pages")
    }
  }

  @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
    if let value, !value.isEmpty {
      GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
  }

  private func startSearch() {
    guard let parsed = BookMetadataQuery(query), !isSearching, !service.sources.isEmpty else { return }
    reset()
    submittedQuery = parsed
    let service = service
    let sources = service.sources.filter { sourceID == "all" || $0.id == sourceID }
    batches = sources.map { MetadataSearchBatch(source: $0) }
    isSearching = true
    let request = generation
    searchTask = Task {
      await withTaskGroup(of: MetadataSearchBatch.self) { group in
        for source in sources { group.addTask { await service.batch(parsed, source: source) } }
        for await batch in group {
          guard !Task.isCancelled, generation == request else { group.cancelAll(); break }
          if let index = batches.firstIndex(where: { $0.id == batch.id }) { batches[index] = batch }
        }
      }
      if generation == request { isSearching = false }
    }
  }

  private func select(_ hit: MetadataSearchHit) {
    cancelSelection()
    selected = hit
    preview = nil
    detailError = nil
    isResolving = true
    let request = selectionID
    let service = service
    selectionTask = Task {
      defer { if selectionID == request { isResolving = false } }
      do {
        let book = try await service.resolve(hit)
        guard !Task.isCancelled, selectionID == request else { return }
        preview = book
      } catch {
        if !Task.isCancelled, selectionID == request { detailError = error.localizedDescription }
      }
    }
  }

  private func apply() {
    guard let preview, let selected, !isResolving else { return }
    guard translators.isEnabled(selected.source.id) else { reset(); return }
    onSelect(preview)
    dismiss()
  }

  private func cancelSelection() {
    selectionTask?.cancel()
    selectionID = UUID()
    isResolving = false
  }

  private func reset() {
    searchTask?.cancel()
    generation = UUID()
    cancelSelection()
    isSearching = false
    batches = []
    selected = nil
    preview = nil
    detailError = nil
    submittedQuery = nil
  }
}
