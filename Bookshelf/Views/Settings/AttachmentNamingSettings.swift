import SwiftData
import SwiftUI

struct AttachmentNamingSettings: View {
  @State private var configuring = false

  var body: some View {
    Button(L10n.tr("配置附件重命名…")) { configuring = true }
      .sheet(isPresented: $configuring) { AttachmentRenameConfiguration() }
  }
}

private struct AttachmentRenameConfiguration: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @EnvironmentObject private var locations: LibraryLocationController
  @Query(filter: #Predicate<Book> { $0.deletedAt == nil }, sort: \Book.updatedAt, order: .reverse) private var books: [Book]
  @State private var rule = AttachmentRenameRule.load()
  @State private var review: RenameReview?
  @State private var feedback: String?

  private var preview: String? {
    let sample: BookArchive
    if let book = books.first { sample = BookArchive(book: book) }
    else {
      var example = BookArchive(book: Book(title: L10n.tr("示例书名")))
      example.contributors = [ContributorArchive(name: L10n.tr("示例作者"), roleRaw: "author", displayOrder: 0)]
      example.publicationDate = "2024"
      example.isbn13 = "9781234567897"
      sample = example
    }
    guard let stem = try? AttachmentNaming.stem(book: sample, pattern: rule.pattern) else { return nil }
    return try? AttachmentNaming.filename(stem: stem, original: "preview.pdf")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(L10n.tr("配置附件重命名")).font(.title2.weight(.semibold))
      HStack {
        Text(L10n.tr("书库")).bold()
        Label(L10n.tr("我的书库"), systemImage: "books.vertical")
          .help(locations.currentStoreURL.deletingLastPathComponent().path)
      }

      VStack(alignment: .leading, spacing: 12) {
        Toggle(L10n.tr("自动重命名新添加的文件"), isOn: $rule.automatic)
        Toggle(L10n.tr("也重命名链接文件的原文件"), isOn: $rule.linked)
          .padding(.leading, 20)
      }.toggleStyle(.checkbox)

      Divider()
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(L10n.tr("文件名模板")).font(.headline)
          Spacer()
          Button(L10n.tr("恢复默认格式")) { rule.pattern = AttachmentNaming.defaultPattern }
            .disabled(rule.pattern == AttachmentNaming.defaultPattern)
        }
        TextEditor(text: $rule.pattern).font(.system(.body, design: .monospaced))
          .padding(5).frame(height: 76)
          .background(Color(nsColor: .textBackgroundColor))
          .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
          .accessibilityLabel(L10n.tr("文件名模板"))
        Text(verbatim: AttachmentNaming.tokens.joined(separator: "    ")).font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary).textSelection(.enabled)
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(L10n.tr("文件名预览")).font(.headline)
        if let preview { Text(verbatim: preview).textSelection(.enabled) }
        else { Text(L10n.tr("命名格式须包含受支持的字段。")).foregroundStyle(.red) }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if let feedback { Text(feedback).foregroundStyle(.secondary).textSelection(.enabled) }
      Divider()
      HStack {
        Button(L10n.tr("重命名已有附件…"), action: prepareReview)
          .disabled(!AttachmentNaming.valid(rule.pattern) || !books.contains { $0.attachmentIDs?.isEmpty == false })
        Spacer()
        Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(L10n.tr("完成")) { rule.save(); dismiss() }
          .keyboardShortcut(.defaultAction).disabled(!AttachmentNaming.valid(rule.pattern))
      }
    }.padding(24).frame(width: 636)
      .onChange(of: rule) { _, _ in feedback = nil }
      .sheet(item: $review) { plan in RenameReviewSheet(plan: plan) }
  }

  private func prepareReview() {
    do {
      let store = try BookAttachmentStore(context: context)
      let changes = try AttachmentRenamePlan.changes(for: books, rule: rule, store: store)
      if changes.isEmpty { feedback = L10n.tr("没有需要重命名的附件。") }
      else { feedback = nil; review = RenameReview(store: store, changes: changes) }
    } catch { feedback = error.localizedDescription }
  }
}

private struct RenameReview: Identifiable {
  let id = UUID()
  let store: BookAttachmentStore
  let changes: [AttachmentRenameChange]
}

private struct RenameReviewSheet: View {
  @Environment(\.dismiss) private var dismiss
  let plan: RenameReview
  @State private var result: AttachmentRenamePlan.Result?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(L10n.tr("重命名已有附件")).font(.headline)
      if let result {
        ScrollView { Text(result.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        HStack { Spacer(); Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.defaultAction) }
      } else {
        List(plan.changes) { change in
          VStack(alignment: .leading, spacing: 4) {
            Label(change.item.name, systemImage: change.item.kind == .linkedFile ? "link" : "doc")
              .foregroundStyle(.secondary)
            Label(change.filename, systemImage: "arrow.turn.down.right")
          }.help(change.book.title)
        }
        HStack {
          Spacer()
          Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
          Button(L10n.tr("重命名 \(plan.changes.count) 个文件")) {
            result = AttachmentRenamePlan.apply(plan.changes, store: plan.store, authorize: chooseAttachmentDirectory)
          }.keyboardShortcut(.defaultAction)
        }
      }
    }.padding(20).frame(width: 560, height: 350)
  }
}
