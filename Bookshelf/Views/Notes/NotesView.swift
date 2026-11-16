import SwiftData
import SwiftUI

struct NoteNavigationActions: Sendable {
  var create: @MainActor @Sendable (UUID?) -> Void = { _ in }
  var open: @MainActor @Sendable (UUID) -> Void = { _ in }
}
private struct NoteNavigationKey: EnvironmentKey {
  static let defaultValue = NoteNavigationActions()
}
extension EnvironmentValues {
  var noteNavigation: NoteNavigationActions {
    get { self[NoteNavigationKey.self] }
    set { self[NoteNavigationKey.self] = newValue }
  }
}

/// Both standalone notes and child notes use the right-hand item inspector.
struct NoteDetailView: View {
  @Environment(\.libraryDisplay) private var display
  @Environment(\.modelContext) private var context
  @Environment(\.libraryUndoManager) private var undoManager
  @Environment(\.noteNavigation) private var navigation
  @Environment(NoteEditingSession.self) private var editing
  @Query private var books: [Book]
  let note: NoteRecord
  let positions: NoteEditorPositionStore
  var onRestore: (() -> Void)? = nil
  var onPurge: (() -> Void)? = nil
  @State private var purgePlan: TrashPlan?
  @State private var state: InlineNoteDraft?
  @State private var errorMessage: String?
  @State private var confirmingPurge = false
  private var parent: Book? { note.parentBookID.flatMap { id in books.first { $0.id == id } } }
  private var trashed: Bool { NoteQueries.isTrashed(note, books: books) }
  private var commands: NoteCommands { NoteCommands(context: context, undoManager: undoManager) }

  var body: some View {
    VStack(spacing: 0) {
      if trashed && state?.hasUnsavedChanges != true {
        MarkdownNotePreview(source: note.body)
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          Text(parent?.deletedAt != nil ? L10n.tr("所属书籍在回收站中，请先恢复书籍。") : L10n.tr("笔记在回收站中，恢复后可编辑。"))
            .font(display.font).foregroundStyle(.secondary)
          HStack {
            Button(L10n.tr("恢复笔记")) {
              if let onRestore { onRestore() }
              else { perform { try commands.setTrashed(false, expected: note) } }
            }
              .disabled(note.deletedAt == nil || parent?.deletedAt != nil)
            Spacer()
            Button(L10n.tr("永久删除…"), role: .destructive) {
              if let onPurge { onPurge() }
              else { perform {
                purgePlan = try TrashCommands(context: context, undoManager: undoManager).preview([.note(note.id)])
                confirmingPurge = true
              } }
            }
          }
        }.padding(12)
      } else if let state {
        MarkdownNoteEditor(text: textBinding(state, \.body),
          focusToken: editing.focusRequest?.noteID == note.id ? editing.focusRequest?.token : nil,
          noteID: note.id, positions: positions)
        if let message = state.errorMessage {
          Divider()
          VStack(alignment: .leading, spacing: 8) {
            Text(message).font(display.font).foregroundStyle(.red).textSelection(.enabled)
            HStack {
              Button(L10n.tr("重试保存")) { editing.save(state, context: context, undoManager: undoManager) }
              Button(L10n.tr("另存为新笔记")) { perform {
                let copy = try editing.saveCopy(state, context: context, undoManager: undoManager)
                navigation.open(copy.id)
              } }
            }.font(display.font)
          }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
      } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
      if let errorMessage {
        Text(errorMessage).font(display.font).foregroundStyle(.red).textSelection(.enabled).padding(12)
      }
    }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor))
      .onAppear { state = editing.open(note) }
      .onChange(of: note) { _, value in state?.reconcile(value) }
      .confirmationDialog(purgePlan?.confirmationTitle ?? L10n.tr("永久删除这条笔记？"), isPresented: $confirmingPurge, titleVisibility: .visible) {
        Button(L10n.tr("永久删除"), role: .destructive) { perform {
          guard let plan = purgePlan else { return }
          defer { purgePlan = nil }
          try TrashCommands(context: context, undoManager: undoManager).purge(plan)
        } }
        Button(L10n.tr("取消"), role: .cancel) { purgePlan = nil }
      } message: { Text(purgePlan?.confirmationMessage ?? "") }
  }
  private func textBinding(_ state: InlineNoteDraft, _ key: WritableKeyPath<NoteRecord, String>) -> Binding<String> {
    Binding(get: { state.value[keyPath: key] }, set: { value in
      editing.update(state, context: context, undoManager: undoManager) { $0.value[keyPath: key] = value }
    })
  }
  private func perform(_ operation: () throws -> Void) { do { try operation(); errorMessage = nil } catch { errorMessage = error.localizedDescription } }
}

struct ChildNotesView: View {
  @Environment(\.libraryDisplay) private var display
  @Environment(\.noteNavigation) private var navigation
  let notes: [NoteRecord]
  let isReadOnly: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: display.inspectorRowSpacing) {
      ForEach(notes) { note in
        Button { navigation.open(note.id) } label: {
          Label(note.displayTitle, systemImage: "note.text").font(display.font).lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: display.inspectorRowHeight, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
          .modifier(NoteRowActions(note: note, isTrashed: isReadOnly))
      }
    }
  }
}

/// Note actions stay on the item, keeping the writing surface free of controls.
private struct NoteRowActions: ViewModifier {
  @Environment(\.modelContext) private var context
  @Environment(\.libraryUndoManager) private var undoManager
  @Environment(\.noteNavigation) private var navigation
  @Environment(NoteEditingSession.self) private var editing
  let note: NoteRecord
  let isTrashed: Bool
  @State private var errorMessage: String?

  func body(content: Content) -> some View {
    content.contextMenu {
      Button(isTrashed ? L10n.tr("查看笔记") : L10n.tr("编辑笔记")) { navigation.open(note.id) }
      if !isTrashed {
        Divider()
        Button(L10n.tr("移入回收站"), role: .destructive) {
          do { try NoteCommands(context: context, undoManager: undoManager).setTrashed(true, expected: note) }
          catch { errorMessage = error.localizedDescription }
        }.disabled(editing.drafts[note.id]?.hasUnsavedChanges == true)
      }
    }
    .alert(L10n.tr("无法修改笔记"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
      Button(L10n.tr("好"), role: .cancel) { errorMessage = nil }
    } message: { Text(errorMessage ?? "") }
  }
}
