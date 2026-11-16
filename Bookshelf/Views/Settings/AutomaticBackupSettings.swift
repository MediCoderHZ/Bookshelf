import AppKit
import SwiftUI

struct AutomaticBackupSettings: View {
  @ObservedObject var backups: AutomaticBackupController
  let onHistory: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Toggle(L10n.tr("定期备份书籍和笔记"), isOn: $backups.isEnabled)
      SettingsControlRow(title: L10n.tr("备份频率")) {
        Picker(L10n.tr("备份频率"), selection: $backups.intervalHours) {
          Text(L10n.tr("每小时")).tag(1)
          Text(L10n.tr("每 6 小时")).tag(6)
          Text(L10n.tr("每天")).tag(24)
        }.labelsHidden().frame(width: 210, alignment: .leading).disabled(!backups.isEnabled)
      }
      SettingsControlRow(title: L10n.tr("保留定时与手动备份")) {
        Picker(L10n.tr("保留定时与手动备份"), selection: $backups.retentionCount) {
          ForEach([7, 30, 90], id: \.self) { Text(L10n.tr("最近 \($0) 份")).tag($0) }
        }.labelsHidden().frame(width: 210, alignment: .leading)
      }
      SettingsControlRow(title: L10n.tr("最近成功备份")) {
        Text(backups.lastBackup?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)) ?? L10n.tr("尚未完成"))
          .textSelection(.enabled)
      }
      HStack(spacing: 12) {
        Button(L10n.tr("立即备份")) { _ = try? backups.create() }
        Button(L10n.tr("查看历史备份…"), action: onHistory)
      }
      SettingsHelp(L10n.tr("运行期间按时备份，关闭或休眠错过的备份在下次运行时补做。升级前始终额外备份，并单独保留最近 10 份；关闭定期备份不关闭升级保护。"))
      SettingsHelp(L10n.tr("备份保存在本机，不能防止整块磁盘损坏。可通过历史备份窗口导出 JSON 到其他磁盘。"))
      if let message = backups.lastError {
        Text(L10n.tr("备份未完成：") + message).foregroundStyle(.red).textSelection(.enabled)
      }
      if let message = backups.cleanupWarning { Text(message).foregroundStyle(.secondary) }
    }
  }
}

struct AutomaticBackupHistoryView: View {
  @ObservedObject var backups: AutomaticBackupController
  let onRestore: (Data) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var errorMessage: String?
  @State private var exportDocument = LibraryBackupDocument()
  @State private var isExporting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(L10n.tr("历史备份")).font(.title2)
        Spacer()
        Button(L10n.tr("刷新")) { backups.refresh() }
      }
      Text(backups.store.directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      List(backups.entries) { entry in
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale))).fontWeight(.medium)
            Spacer()
            Text(entry.kind.title).foregroundStyle(.secondary)
          }
          HStack {
            if let count = entry.bookCount {
              Text(L10n.tr("\(count) 条书籍 · \(entry.noteCount ?? 0) 条笔记（含回收站）")).font(.caption)
            } else { Text(L10n.tr("数据库快照 · 保留升级前原始数据")).font(.caption) }
            Spacer()
            if entry.hasJSON {
              Button(L10n.tr("导出…")) { perform {
                exportDocument = LibraryBackupDocument(data: try backups.store.archiveData(for: entry))
                isExporting = true
              } }
              Button(L10n.tr("恢复…")) { perform {
                onRestore(try backups.store.archiveData(for: entry)); dismiss()
              } }
            }
            Button(L10n.tr("显示文件")) {
              NSWorkspace.shared.activateFileViewerSelecting([backups.store.directory.appendingPathComponent(entry.directoryName)])
            }
          }
        }.padding(.vertical, 5)
      }
      if backups.entries.isEmpty { Text(L10n.tr("暂无通过校验的备份。可点击“立即备份”创建。")).foregroundStyle(.secondary) }
      Text(L10n.tr("恢复会先预览，确认后才合并到书库；不会直接覆盖数据库。升级前原始快照用于数据库故障排查，应保留原文件。损坏或不认识的备份不会自动清理。")).font(.caption).foregroundStyle(.secondary)
      if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
      HStack { Spacer(); Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction) }
    }
    .padding(20).frame(width: 700, height: 500)
    .onAppear { backups.refresh() }
    .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json,
      defaultFilename: L10n.tr("书架历史备份")) { result in
      if case .failure(let error) = result { errorMessage = error.localizedDescription }
    }
  }
  private func perform(_ action: () throws -> Void) {
    do { try action(); errorMessage = nil } catch { errorMessage = error.localizedDescription }
  }
}

struct AutomaticBackupWarning: View {
  @ObservedObject var backups: AutomaticBackupController
  var body: some View {
    if let message = backups.lastError {
      HStack {
        Image(systemName: "exclamationmark.triangle")
        Text(L10n.tr("自动备份未完成：") + message).font(.caption).textSelection(.enabled)
        Spacer()
        Button(L10n.tr("重试备份")) { _ = try? backups.create() }
      }.padding(8).background(.yellow.opacity(0.12))
    }
  }
}
