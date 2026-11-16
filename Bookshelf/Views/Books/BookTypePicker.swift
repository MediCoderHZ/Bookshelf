import SwiftUI

/// Only the three supported categories are selectable. Legacy nil values remain unclassified.
struct BookTypePicker: View {
  @Binding var selection: BookType?
  var emptyLabel = L10n.tr("选择条目类型…")

  var body: some View {
    Menu {
      ForEach(BookType.allCases) { type in
        Button {
          selection = type
        } label: {
          if selection == type { Label(type.title, systemImage: "checkmark") }
          else { Text(type.title) }
        }
      }
    } label: {
      Text(selection?.title ?? emptyLabel)
        .frame(minWidth: selection == nil && emptyLabel.isEmpty ? 40 : nil, alignment: .leading)
    }
    .menuStyle(.borderlessButton).fixedSize()
    .accessibilityLabel(L10n.tr("条目类型"))
    .accessibilityValue(selection?.title ?? L10n.tr("尚未选择"))
    .help(L10n.tr("选择条目类型；中文译本显示作者和译者。切换类型保留已录入的信息。"))
  }
}
