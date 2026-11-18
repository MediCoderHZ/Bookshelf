import SwiftUI
import UniformTypeIdentifiers

struct WebMetadataImportView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(TranslatorStore.self) private var translators
  var testTranslatorID: String? = nil
  let onSelect: (BookMetadataSearchResult) -> Void

  @State private var address = ""
  @State private var extraction: WebTranslationResult?
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var task: Task<Void, Never>?
  @State private var isChoosingHTML = false

  private var registry: WebTranslatorRegistry {
    let all = translators.registry
    guard let testTranslatorID else { return all }
    return WebTranslatorRegistry(translators: all.translators.filter { $0.descriptor.id == testTranslatorID },
      disabledIDs: all.disabledIDs)
  }

  private var engine: TranslationEngine {
    let web = registry
    return TranslationEngine(registry: TranslatorRegistry(translators: web.translators.map { $0 as any BookTranslator }, disabledIDs: web.disabledIDs))
  }

  private var translatorStatus: String {
    if let extraction { return "\(extraction.translator.name) · v\(extraction.translator.version)" }
    let matches = (try? registry.matching(address)) ?? []
    return matches.isEmpty ? L10n.tr("输入网址以匹配解析器") : L10n.tr("候选：") + matches.map(\.descriptor.name).joined(separator: "、")
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          TextField(L10n.tr("图书详情页或列表页链接"), text: $address)
            .textFieldStyle(.roundedBorder)
            .onSubmit(extract)
            .disabled(isWorking)
            .accessibilityLabel(L10n.tr("网页链接"))
          Button(L10n.tr("提取"), action: extract)
            .disabled(isWorking || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text(L10n.tr("点击提取会向所填网址请求页面。网站会收到 IP 地址等网络信息，书库和笔记不会随请求发送。"))
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          if let raw = URL(string: address), let url = WebURLPolicy.normalized(raw) {
            Link(L10n.tr("在浏览器查看此页"), destination: url)
          }
          Spacer()
          Text(translatorStatus)
            .foregroundStyle(.secondary)
        }.font(.caption)
        HStack(alignment: .top) {
          Button(L10n.tr("导入已保存网页…")) { isChoosingHTML = true }
            .disabled(isWorking || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Text(L10n.tr("直连失败时，可在浏览器将该页保存为 HTML，然后导入。上方填写该页的原始链接。"))
            .font(.caption).foregroundStyle(.secondary)
        }
        if testTranslatorID != nil {
          Label(L10n.tr("测试模式：只预览，不写入书库。"), systemImage: "testtube.2").font(.caption)
        }
        if isWorking {
          HStack {
            ProgressView().controlSize(.small)
            Text(L10n.tr("正在读取…"))
            Spacer()
            Button(L10n.tr("停止")) { stop() }
          }
        }
        if let errorMessage {
          Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
        }
        Divider()
        switch extraction?.page {
        case .choices(let books):
          Text(L10n.tr("选择一本书，读取其详情（\(books.count) 本）")).font(.headline)
          List(books) { book in
            Button {
              address = book.url.absoluteString
              extract()
            } label: {
              HStack {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
                Text(book.title).lineLimit(2)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
              }.padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(isWorking)
          }
        case .book(let result):
          ScrollView {
            VStack(alignment: .leading, spacing: 14) {
              Text(result.title).font(.title2.bold()).textSelection(.enabled)
              Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 10) {
                row(L10n.tr("副标题"), result.subtitle)
                row(L10n.tr("原书名"), result.originalTitle)
                row(L10n.tr("作者"), result.authors.joined(separator: "、"))
                row(L10n.tr("译者"), result.translators.joined(separator: "、"))
                row(L10n.tr("出版社"), result.publisher)
                row(L10n.tr("出版日期"), result.publicationDate)
                row("ISBN", result.preferredISBN)
                row(L10n.tr("页数"), result.pageCount.map(String.init))
              }
              if let description = result.bookDescription {
                Text(L10n.tr("简介")).font(.headline)
                Text(description).textSelection(.enabled)
              }
              if let source = result.sourceURL { Link(L10n.tr("来源：\(result.sourceName)"), destination: source) }

              Text(testTranslatorID == nil
                ? L10n.tr("仅填充网页提供的字段，缺失信息保留现有内容。请核对版本、作者与 ISBN，最后在编辑页点击保存。")
                : L10n.tr("请对照网页检查字段是否正确。此测试只预览结果，不保存书籍。"))
                .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        case nil:
          ContentUnavailableView(
            L10n.tr("从网页添加书籍"), systemImage: "link",
            description: Text(L10n.tr("粘贴网址后自动匹配解析器。更多网站可在设置 → 文件与数据库 → 元信息解析器中导入规则。")))
        }
      }
      .padding(22)
      .navigationTitle(testTranslatorID == nil ? L10n.tr("从网页提取") : L10n.tr("测试网页解析器"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.tr("取消")) { stop(); dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          if case .book(let result) = extraction?.page {
            if testTranslatorID != nil {
              Button(L10n.tr("完成预览")) { stop(); dismiss() }.keyboardShortcut(.defaultAction)
            } else {
              Button(L10n.tr("填入编辑页")) { apply(result) }
                .disabled(isWorking).keyboardShortcut(.defaultAction)
            }
          }
        }
      }
    }
    .frame(width: 680, height: 660)
    .fileImporter(isPresented: $isChoosingHTML, allowedContentTypes: [.html]) { result in
      importSavedPage(result)
    }
    .onDisappear { task?.cancel() }
    .onChange(of: translators.revision) { _, _ in stop(); extraction = nil }
    .onChange(of: address) { _, _ in extraction = nil; errorMessage = nil }
  }

  @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
    if let value, !value.isEmpty {
      GridRow {
        Text(title).foregroundStyle(.secondary)
        Text(value).textSelection(.enabled)
      }
    }
  }

  private func extract() {
    guard !isWorking else { return }
    extraction = nil
    errorMessage = nil
    isWorking = true
    let input = address
    let engine = engine
    task = Task {
      defer { isWorking = false }
      do {
        let result = try await engine.extractWeb(input)
        try Task.checkCancellation()
        extraction = result
      } catch {
        if !Task.isCancelled { errorMessage = error.localizedDescription }
      }
    }
  }

  private func apply(_ result: BookMetadataSearchResult) {
    guard !isWorking, let extraction, translators.isEnabled(extraction.translator.id) else { return }
    onSelect(result)
    dismiss()
  }

  private func stop() {
    task?.cancel()
    // The task clears isWorking after cancellation, preventing stale tasks overwriting a new request.
  }

  private func importSavedPage(_ result: Result<URL, Error>) {
    guard !isWorking else { return }
    errorMessage = nil
    extraction = nil
    do {
      let url = try result.get()
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= WebMetadataClient.htmlLimit else { throw WebMetadataError.tooLarge }
      extraction = try engine.extractHTML(Data(contentsOf: url), sourceURL: address)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
