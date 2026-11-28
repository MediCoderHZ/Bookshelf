import SwiftUI

struct AIBookCompletionView: View {
  let draft: BookArchive
  let onSuggestion: (MetadataUpdateProposal) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openSettings) private var openSettings
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.tr("AI 补全元信息")).font(.title2.weight(.semibold))
      Text(draft.title).lineLimit(2)
      if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
      else { ProgressView(L10n.tr("正在请求模型…")).controlSize(.small) }
      HStack {
        if error != nil {
          Button(L10n.tr("打开 AI 设置…")) {
            dismiss()
            AISettingsNavigation.open(openSettings)
          }
        }
        Spacer()
        Button(L10n.tr("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.padding(22).frame(width: 460)
    .task {
      do {
        let config = try AIModelConfiguration.saved()
        let suggestion = try await AIModelClient.complete(draft, configuration: config, key: AIModelCredential.read(config.base))
        try Task.checkCancellation()
        onSuggestion(suggestion)
        dismiss()
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }
}

struct MCPReviewBanner: View {
  @Environment(AIMetadataWorkspace.self) private var workspace
  @Environment(\.libraryUndoManager) private var undoManager
  @State private var reviewing: MetadataUpdateProposal?
  var body: some View {
    if let next = workspace.pending.first {
      HStack {
        Label(L10n.tr("AI 元信息建议 · \(next.current.title)（\(workspace.pending.count)）"), systemImage: "sparkles")
          .lineLimit(1)
        Spacer()
        Button(L10n.tr("忽略")) { workspace.discard(next.id) }
        Button(L10n.tr("核对建议…")) { reviewing = next }
      }.padding(10)
      .sheet(item: $reviewing) { proposal in
        MetadataUpdateView(proposal: proposal) { fields in
          try workspace.accept(proposal, fields: fields, undoManager: undoManager)
        }
      }
    }
  }
}

@MainActor
enum AISettingsNavigation {
  static let request = Notification.Name("Bookshelf.showAISettings")
  static var requested = false
  static func open(_ action: OpenSettingsAction) {
    requested = true
    action()
    NotificationCenter.default.post(name: request, object: nil)
  }
}
