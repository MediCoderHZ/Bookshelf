import AppKit
import SwiftUI

struct AIModelSettings: View {
  @State private var base = UserDefaults.standard.string(forKey: AIModelConfiguration.baseKey) ?? ""
  @State private var model = UserDefaults.standard.string(forKey: AIModelConfiguration.modelKey) ?? ""
  @State private var key = ""
  @State private var message: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
        GridRow { Text(L10n.tr("服务地址")); TextField("https://…/v1", text: $base) }
        GridRow { Text(L10n.tr("模型名称")); TextField(L10n.tr("服务提供的模型 ID"), text: $model) }
        GridRow { Text("API Key"); SecureField(L10n.tr("可选，留空保留现有密钥"), text: $key) }
      }
      HStack {
        Button(L10n.tr("保存配置")) {
          perform {
            let configuration = try AIModelConfiguration(base: base, model: model)
            let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !secret.isEmpty { try AIModelCredential.save(secret, for: configuration.base) }
            UserDefaults.standard.set(configuration.base.absoluteString, forKey: AIModelConfiguration.baseKey)
            UserDefaults.standard.set(configuration.model, forKey: AIModelConfiguration.modelKey)
            key = ""
            message = L10n.tr("模型配置已保存。")
          }
        }
        Button(L10n.tr("移除此服务的密钥")) {
          perform {
            let configuration = try AIModelConfiguration(base: base, model: model)
            try AIModelCredential.remove(configuration.base)
            key = ""
            message = L10n.tr("密钥已移除。")
          }
        }.disabled(base.isEmpty || model.isEmpty)
      }
      if let message { Text(message).font(.callout).textSelection(.enabled) }
    }
  }
  private func perform(_ action: () throws -> Void) {
    do { try action() } catch { message = error.localizedDescription }
  }
}

struct MCPConnectionSettings: View {
  @Environment(AIMetadataWorkspace.self) private var workspace
  @State private var copied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(L10n.tr("允许本机 AI 客户端通过 MCP 访问书目"), isOn: Binding(get: { workspace.enabled },
        set: { copied = false; workspace.setEnabled($0) }))
      if workspace.listening {
        Button(copied ? L10n.tr("已复制 MCP 配置") : L10n.tr("复制 MCP 客户端配置")) {
          let config: [String: Any] = ["mcpServers": ["bookshelf": ["command": "/usr/bin/nc", "args": ["-U", workspace.socket.path]]]]
          if let bytes = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(String(decoding: bytes, as: UTF8.self), forType: .string)
          }
        }
      }
      if let error = workspace.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
    }
  }
}
