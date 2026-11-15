import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BibliographicExportRequest: Identifiable {
  let id = UUID()
  let records: [BookArchive]
  let scopeName: String
}

struct BibliographicDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.bookshelfRIS, .commaSeparatedText, .plainText] }
  // fileExporter falls back to the first writable type unless the exact type is listed.
  static var writableContentTypes: [UTType] { BuiltinTranslators.catalog.compactMap { ($0 as? any FileExportTranslator)?.contentType } }
  var data: Data
  init(data: Data = Data()) { self.data = data }
  init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension FileExportTranslator {
  var contentType: UTType {
    fileExtension == "ris" ? .bookshelfRIS : UTType(filenameExtension: fileExtension, conformingTo: .data) ?? .data
  }
}

extension UTType {
  static let bookshelfRIS = UTType(importedAs: "org.bookshelf.ris", conformingTo: .plainText)
}

/// Presenters live outside responsive menus so resizing cannot dismiss an import or export.
@MainActor @Observable final class BibliographicExchangePresentation {
  var isImporting = false
  var importPlan: LibraryImportPlan?
  var exportRequest: BibliographicExportRequest?
  var message: String?
  var pendingMessage: String?

  func prepareExport(_ books: [Book], scope: String) {
    exportRequest = BibliographicExportRequest(records: books.map { BookArchive(book: $0) }, scopeName: scope)
  }
}

struct BibliographicExchangeMenu: View {
  let books: [Book]
  var selectedBooks: [Book] = []
  var scopeName = "当前结果"
  var iconOnly = false
  var presentation: BibliographicExchangePresentation? = nil
  @State private var ownPresentation = BibliographicExchangePresentation()
  @State private var translators = TranslatorStore.shared
  private var presenter: BibliographicExchangePresentation { presentation ?? ownPresentation }
  private var active: [Book] { books.filter { $0.deletedAt == nil } }
  private var selected: [Book] { selectedBooks.filter { $0.deletedAt == nil } }

  var body: some View {
    if presentation == nil {
      menu.modifier(BibliographicExchangePresenter(presentation: ownPresentation))
    } else { menu }
  }

  private var menu: some View {
    Menu {
      Button("导入 RIS 书目…") { presenter.isImporting = true }.disabled(!translators.isEnabled("ris"))
      Divider()
      Button("导出\(scopeName)（\(active.count) 本）…") { presenter.prepareExport(active, scope: scopeName) }
        .disabled(active.isEmpty)
      if !selectedBooks.isEmpty {
        Button("导出所选书籍（\(selected.count) 本）…") { presenter.prepareExport(selected, scope: "所选书籍") }
          .disabled(selected.isEmpty)
      }
    } label: {
      if iconOnly { LibraryToolbarLabel("导入/导出", systemImage: "square.and.arrow.up") }
      else { Label("导入/导出", systemImage: "square.and.arrow.up") }
    }
    .menuStyle(.borderlessButton)
    .accessibilityLabel("导入/导出")
    .help("导入 RIS，或导出当前结果与所选书籍")
    .fixedSize()
  }
}

struct BibliographicExchangePresenter: ViewModifier {
  @Environment(\.modelContext) private var context
  @Bindable var presentation: BibliographicExchangePresentation
  @State private var translators = TranslatorStore.shared

  func body(content: Content) -> some View {
    content
      .fileImporter(isPresented: $presentation.isImporting, allowedContentTypes: [.bookshelfRIS, .plainText], allowsMultipleSelection: false) { result in
        do {
          guard let url = try result.get().first else { return }
          let access = url.startAccessingSecurityScopedResource()
          defer { if access { url.stopAccessingSecurityScopedResource() } }
          let data = try Data(contentsOf: url, options: .mappedIfSafe)
          presentation.importPlan = try LibraryImportPlanner.prepareRIS(data, context: context, registry: translators.catalog)
        } catch { presentation.message = error.localizedDescription }
      }
      .sheet(item: $presentation.exportRequest) { BibliographicExportView(request: $0) }
      .sheet(item: $presentation.importPlan, onDismiss: {
        presentation.message = presentation.pendingMessage; presentation.pendingMessage = nil
      }) { plan in
        ImportPreviewView(plan: plan) {
          presentation.pendingMessage = [plan.importSummary, $0.message].compactMap { $0 }.joined(separator: "\n")
        }
      }
      .alert("书目导入导出", isPresented: Binding(get: { presentation.message != nil }, set: { if !$0 { presentation.message = nil } })) {
        Button("好", role: .cancel) {}
      } message: { Text(presentation.message ?? "") }
  }
}

struct BibliographicExportView: View {
  @Environment(\.dismiss) private var dismiss
  let request: BibliographicExportRequest
  @State private var translators = TranslatorStore.shared
  @State private var formatID = "ris"
  @State private var includeNotes = false
  @State private var document = BibliographicDocument()
  @State private var isExporting = false
  @State private var errorMessage: String?
  private var active: [BookArchive] { request.records.filter { $0.deletedAt == nil } }
  private var formats: [any FileExportTranslator] {
    translators.catalog.ordered.compactMap { $0 as? any FileExportTranslator }.filter { translators.isEnabled($0.descriptor.id) }
  }
  private var format: (any FileExportTranslator)? { formats.first { $0.descriptor.id == formatID } }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Text("\(request.scopeName) · \(active.count) 本书").font(.headline)
        Picker("导出格式", selection: $formatID) {
          ForEach(formats, id: \.descriptor.id) { Text($0.descriptor.name).tag($0.descriptor.id) }
        }.pickerStyle(.segmented)
        Text(format?.exportSummary ?? "没有启用的导出解析器，请在设置中启用 RIS 或 CSV。")
          .font(.callout).foregroundStyle(.secondary)
        Toggle("包含书籍备注", isOn: $includeNotes).toggleStyle(.checkbox)
        Text("独立笔记、书籍子笔记、文件夹层级、回收站和智能规则不在此文件中。完整迁移请使用 JSON 备份。")
          .font(.caption).foregroundStyle(.secondary)
        Divider()
        Text("导出范围预览").font(.headline)
        List(active, id: \.id) { book in
          HStack {
            Text(book.title)
            Spacer()
            Text(BookField.authors.value(in: book)).foregroundStyle(.secondary)
          }
        }.frame(minHeight: 160)
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      }.padding(22)
      .navigationTitle("导出书籍清单")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("选择保存位置…") {
            do {
              document = BibliographicDocument(data: try TranslationEngine(registry: translators.catalog)
                .exportFile(active, translatorID: formatID, includeNotes: includeNotes))
              isExporting = true
            } catch { errorMessage = error.localizedDescription }
          }.disabled(active.isEmpty || format == nil)
        }
      }
    }.frame(width: 720, height: 570)
      .onAppear {
        if format == nil, let first = formats.first { formatID = first.descriptor.id }
      }
      .fileExporter(isPresented: $isExporting, document: document, contentType: format?.contentType ?? .data,
        defaultFilename: "书籍清单.\(format?.fileExtension ?? "txt")") { result in
        switch result {
        case .success: dismiss()
        case .failure(let error): errorMessage = error.localizedDescription
        }
      }
  }
}
