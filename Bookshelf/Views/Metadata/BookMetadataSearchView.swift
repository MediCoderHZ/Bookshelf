import SwiftUI

struct BookMetadataSearchView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var translators = TranslatorStore.shared
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
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          TextField("输入书名或 ISBN", text: $query)
            .textFieldStyle(.roundedBorder).onSubmit(startSearch)
            .accessibilityLabel("书名或 ISBN")
          Picker("来源", selection: $sourceID) {
            Text("全部已启用来源").tag("all")
            ForEach(service.sources) { Text($0.name).tag($0.id) }
          }.frame(width: 240)
          Button("搜索", action: startSearch)
            .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if isSearching { Button("停止") { reset() } }
        }
        Text("点击搜索会将书名或 ISBN 发送至所选来源。选择候选后读取详情，核对版本再填入。停用的解析器不参与搜索。")
          .font(.caption).foregroundStyle(.secondary)
        Divider()
        HStack(spacing: 0) {
          resultList.frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
          Divider()
          detail.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.leading, 18)
        }
      }
      .padding(18)
      .navigationTitle("搜索书籍元信息")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { reset(); dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("填入编辑页", action: apply)
            .disabled(preview == nil || isResolving).keyboardShortcut(.defaultAction)
        }
      }
    }
    .frame(minWidth: 920, minHeight: 650)
    .onChange(of: query) { _, _ in reset() }
    .onChange(of: sourceID) { _, _ in reset() }
    .onChange(of: translators.revision) { _, _ in
      reset()
      if sourceID != "all" && !service.sources.contains(where: { $0.id == sourceID }) { sourceID = "all" }
    }
    .onDisappear { reset() }
  }

  @ViewBuilder private var resultList: some View {
    if batches.isEmpty {
      ContentUnavailableView("按书名或 ISBN 搜索", systemImage: "magnifyingglass",
        description: Text("可选择豆瓣、Goodreads、Open Library，或同时查询全部已启用来源。"))
    } else {
      List {
        ForEach(batches) { batch in
          Section {
            if batch.isLoading {
              HStack { ProgressView().controlSize(.small); Text("正在搜索…") }
            } else if let error = batch.error {
              Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
              if let query = submittedQuery, let url = service.searchURL(for: query, source: batch.source) {
                Link("在浏览器查看搜索结果", destination: url).font(.caption)
              }
            } else if batch.hits.isEmpty {
              Text("未找到结果，可尝试其他书名或 ISBN。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(batch.hits) { hit in
              Button { select(hit) } label: {
                HStack(alignment: .top) {
                  Image(systemName: selected?.id == hit.id ? "checkmark.circle.fill" : "book.closed")
                    .foregroundStyle(selected?.id == hit.id ? Color.accentColor : .secondary)
                  VStack(alignment: .leading, spacing: 5) {
                    Text(hit.title).font(.headline).lineLimit(2)
                    if let subtitle = hit.subtitle, !subtitle.isEmpty {
                      Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Text(hit.source.name).font(.caption2).foregroundStyle(.secondary)
                  }
                  Spacer(minLength: 0)
                }.padding(.vertical, 5).contentShape(Rectangle())
              }.buttonStyle(.plain)
            }
          } header: {
            Text(batch.isLoading ? batch.source.name : "\(batch.source.name) · \(batch.hits.count) 项")
          }
        }
      }.listStyle(.inset)
    }
  }

  @ViewBuilder private var detail: some View {
    if isResolving {
      VStack(spacing: 14) {
        ProgressView()
        Text("正在读取图书详情…")
        Button("停止读取") { cancelSelection() }
      }
    } else if let book = preview {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text(book.title).font(.title2.bold()).textSelection(.enabled)
          Text("来源：\(book.sourceName)").font(.caption).foregroundStyle(.secondary)
          if let warning = MetadataSearchService.isbnNotice(query: submittedQuery, book: book) {
            Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
          }
          Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 10) {
            row("作者", book.authors.joined(separator: "、"))
            row("译者", book.translators.joined(separator: "、"))
            row("出版社", book.publisher)
            row("出版日期", book.publicationDate)
            row("ISBN", book.preferredISBN)
            row("页数", book.pageCount.map(String.init))
            row("语言", book.languageCode)
            row("原书名", book.originalTitle)
          }
          if let description = book.bookDescription { Text(description).textSelection(.enabled) }
          if let url = book.sourceURL { Link("查看来源网页", destination: url) }
          if let detailError { Text(detailError).foregroundStyle(.red) }
          Text("仅填充来源提供的字段，缺失信息保留现有内容。请核对版本，最后在编辑页保存。")
            .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    } else if let detailError {
      VStack(spacing: 12) {
        ContentUnavailableView("暂时无法读取详情", systemImage: "wifi.exclamationmark", description: Text(detailError))
        if let selected { Button("重试读取") { select(selected) } }
        if let url = selected?.candidate?.url { Link("在浏览器查看此版本", destination: url) }
      }
    } else {
      ContentUnavailableView("选择一本书", systemImage: "book.pages",
        description: Text("各来源独立显示结果。选择候选，预览作者和出版信息后填入。"))
    }
  }

  @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
    if let value, !value.isEmpty {
      GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
  }

  private func startSearch() {
    guard let parsed = BookMetadataQuery(query), !isSearching else { return }
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
