import AppKit
import SwiftUI

/// Suggestions only exist beneath the currently edited name; inactive rows remain plain text.
struct ContributorNameInput: View {
  let value: String
  let field: BookField
  let usages: [ContributorNameUsage]
  let focusToken: UUID?
  let onFocus: () -> Void
  let onBegin: () -> Void
  let onChange: (String) -> Void
  let onCommit: () -> Bool
  let onCancel: () -> String
  let currentValue: () -> String
  var body: some View {
    MetadataSuggestionInput(
      input: NativeBookMetadataField(value: value, label: field.label + "姓名", multiline: false,
        focusToken: focusToken, onFocus: onFocus, onBegin: onBegin, onChange: onChange,
        onCommit: onCommit, onCancel: onCancel, currentValue: currentValue),
      suggestions: ContributorNameSuggestions.matches(value, usages: usages, field: field),
      noun: "姓名", systemImage: "person")
  }
}
