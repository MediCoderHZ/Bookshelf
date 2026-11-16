import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class InlineNoteDraft {
  var baseline: NoteRecord
  var value: NoteRecord
  var tagsText: String
  var hasUnsavedChanges = false
  var errorMessage: String?
  init(_ note: NoteRecord) {
    baseline = note; value = note; tagsText = note.tags.joined(separator: "、")
  }
  func reconcile(_ note: NoteRecord) {
    guard !hasUnsavedChanges, baseline != note else { return }
    baseline = note; value = note; tagsText = note.tags.joined(separator: "、")
  }
}

struct NoteFocusRequest: Equatable {
  let noteID: UUID
  let token = UUID()
}

/// Per-window editor state. Every accepted edit is saved synchronously, so switching
/// rows or closing a window cannot race a delayed autosave of a different note.
@MainActor @Observable
final class NoteEditingSession {
  private(set) var drafts: [UUID: InlineNoteDraft] = [:]
  var focusRequest: NoteFocusRequest?
  var recoveryIssue: String?
  private let recovery: NoteDraftRecoveryStore

  init(recovery: NoteDraftRecoveryStore = NoteDraftRecoveryStore()) {
    self.recovery = recovery
    let result = recovery.load()
    for snapshot in result.drafts {
      let state = InlineNoteDraft(snapshot.baseline)
      state.value = snapshot.draft; state.tagsText = snapshot.tagsText; state.hasUnsavedChanges = true
      state.errorMessage = L10n.tr("已恢复未保存草稿。请重试保存，或另存为新笔记以保留两个版本。")
      drafts[snapshot.draft.id] = state
    }
    if !result.errors.isEmpty { recoveryIssue = L10n.tr("部分恢复草稿无法读取，原文件已保留：") + result.errors.joined(separator: "；") }
  }
  var pendingDrafts: [InlineNoteDraft] {
    drafts.values.filter(\.hasUnsavedChanges).sorted { $0.value.createdAt < $1.value.createdAt }
  }
  func open(_ note: NoteRecord) -> InlineNoteDraft {
    if let state = drafts[note.id] { state.reconcile(note); return state }
    let state = InlineNoteDraft(note); drafts[note.id] = state; return state
  }
  func requestFocus(_ id: UUID) { focusRequest = NoteFocusRequest(noteID: id) }

  func update(_ state: InlineNoteDraft, context: ModelContext, undoManager: UndoManager?,
    change: (InlineNoteDraft) -> Void) {
    change(state); state.hasUnsavedChanges = true
    save(state, context: context, undoManager: undoManager)
  }

  @discardableResult
  func save(_ state: InlineNoteDraft, context: ModelContext, undoManager: UndoManager?) -> Bool {
    guard state.hasUnsavedChanges else { return true }
    do {
      var candidate = state.value
      candidate.tags = MetadataNormalizer.contributorNames(from: state.tagsText)
      let saved = try NoteCommands(context: context, undoManager: undoManager).save(candidate, expected: state.baseline)
      state.baseline = saved; state.hasUnsavedChanges = false; state.errorMessage = nil
      state.value.updatedAt = saved.updatedAt
      // Keep raw input/caret stable while typing; only external changes reset the editor.
      clearRecovery(saved.id)
      return true
    } catch {
      state.errorMessage = L10n.tr("尚未保存：") + error.localizedDescription
      do {
        try recovery.save(NoteDraftSnapshot(baseline: state.baseline, draft: state.value, tagsText: state.tagsText))
        state.errorMessage! += L10n.tr(" 草稿已在本机保留。")
      } catch { state.errorMessage! += L10n.tr(" 恢复副本也未能写入，请保留编辑窗口并复制正文：") + error.localizedDescription }
      return false
    }
  }

  func saveCopy(_ state: InlineNoteDraft, context: ModelContext, undoManager: UndoManager?) throws -> NoteRecord {
    var copy = state.value; copy.id = UUID(); copy.createdAt = Date(); copy.updatedAt = copy.createdAt; copy.deletedAt = nil
    copy.tags = MetadataNormalizer.contributorNames(from: state.tagsText)
    let books = try context.fetch(FetchDescriptor<Book>())
    if let parent = copy.parentBookID, !books.contains(where: { $0.id == parent && $0.deletedAt == nil }) { copy.parentBookID = nil }
    let collections = Set(try context.fetch(FetchDescriptor<BookCollection>()).filter { !$0.isSmart }.map(\.id))
    copy.collectionIDs = copy.collectionIDs.filter(collections.contains)
    let saved = try NoteCommands(context: context, undoManager: undoManager).save(copy, expected: nil)
    state.hasUnsavedChanges = false; clearRecovery(state.value.id); drafts[state.value.id] = nil
    return saved
  }

  private func clearRecovery(_ id: UUID) {
    do { try recovery.remove(id) }
    catch { recoveryIssue = L10n.tr("笔记已保存，但旧的恢复副本未能清理：") + error.localizedDescription }
  }
}
