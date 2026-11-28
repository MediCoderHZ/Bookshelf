import AppKit
import SwiftUI

struct AttachmentFolderSettings: View {
  @EnvironmentObject private var locations: LibraryLocationController
  @State private var customPath: String?
  @State private var readError: String?
  @State private var actionError: String?

  private var preferences: AttachmentFolderPreferences {
    AttachmentFolderPreferences(database: locations.currentStoreURL)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let readError {
        Text(readError).foregroundStyle(.red).textSelection(.enabled)
      } else {
        let path = customPath ?? BookAttachmentStore(database: locations.currentStoreURL).root.path
        Label {
          Text(verbatim: path).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: "folder") }
      }
      HStack(spacing: 12) {
        Button(L10n.tr("选择附件文件夹…"), action: chooseFolder)
        if customPath != nil || readError != nil {
          Button(L10n.tr("使用书库文件夹")) {
            do { try preferences.reset(); reload() }
            catch { actionError = error.localizedDescription }
          }
        }
      }
    }
    .onChange(of: locations.currentStoreURL, initial: true) { _, _ in reload() }
    .alert(L10n.tr("附件保存位置"), isPresented: Binding(get: { actionError != nil },
      set: { if !$0 { actionError = nil } })) {
      Button(L10n.tr("好"), role: .cancel) {}
    } message: { Text(actionError ?? "") }
  }

  private func reload() {
    do {
      if let reference = try preferences.reference() {
        customPath = (try? AttachmentFolderPreferences.withDirectory(reference) { $0.path }) ?? reference.path
      } else {
        customPath = nil
      }
      readError = nil
    } catch { readError = error.localizedDescription }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = L10n.tr("选择目录")
    panel.message = L10n.tr("新添加的文件将存入所选文件夹，书库通过软链接访问它们。")
    if let customPath { panel.directoryURL = URL(fileURLWithPath: customPath, isDirectory: true) }
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    do { try preferences.set(folder); reload() }
    catch { actionError = error.localizedDescription }
  }
}

struct LibraryStorageSettings: View {
  @EnvironmentObject private var locations: LibraryLocationController
  @EnvironmentObject private var relauncher: AppRelaunchController
  @State private var errorMessage: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(L10n.tr("当前数据目录")).font(.headline)
      Text(locations.currentStoreURL.deletingLastPathComponent().path).textSelection(.enabled)
        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        Button(L10n.tr("显示数据目录")) { NSWorkspace.shared.selectFile(locations.currentStoreURL.path, inFileViewerRootedAtPath: "") }
        Button(L10n.tr("使用自定义位置…")) { chooseDirectory() }
          .disabled(locations.isChecking || relauncher.isRestarting)
      }
      if let pending = locations.pendingDirectory {
        VStack(alignment: .leading, spacing: 12) {
          Text(L10n.tr("重启后迁移到：\(pending.path)")).textSelection(.enabled)
          HStack(spacing: 12) {
            Button(relauncher.isRestarting ? L10n.tr("正在重启…") : L10n.tr("重启并迁移")) { Task { await relauncher.restart() } }
            Button(L10n.tr("取消目录更改")) {
              do { try locations.cancelDirectoryChange() } catch { errorMessage = error.localizedDescription }
            }
          }.disabled(relauncher.isRestarting || locations.isChecking)
          if let message = relauncher.errorMessage { Text(message).foregroundStyle(.red) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
      }
      if let message = locations.locationError { Text(message).foregroundStyle(.red).textSelection(.enabled) }
      Divider()
      Text(L10n.tr("数据库维护")).font(.headline)
      Button(locations.isChecking ? L10n.tr("正在检查…") : L10n.tr("检查数据库完整性")) { Task { await locations.checkIntegrity() } }
        .disabled(locations.isChecking || relauncher.isRestarting)
      if let result = locations.integrityMessage {
        Label(result, systemImage: locations.integrityPassed ? "checkmark.circle" : "exclamationmark.triangle")
          .foregroundStyle(locations.integrityPassed ? Color.primary : Color.red).textSelection(.enabled)
      }
    }
    .alert(L10n.tr("数据目录"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
      Button(L10n.tr("好"), role: .cancel) {}
    } message: { Text(errorMessage ?? "") }
  }
  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false
    panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
    panel.prompt = L10n.tr("选择目录")
    panel.message = L10n.tr("请选择稳定连接的本地空文件夹，避免云同步目录。选择后不会立即移动数据。")
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do { try locations.requestDirectory(url) }
      catch { errorMessage = error.localizedDescription }
    }
  }
}
