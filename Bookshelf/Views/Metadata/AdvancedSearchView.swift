import SwiftUI

/// Shared field/comparison/value controls for the inline panel and smart-list editor.
private struct SearchRuleRow: View {
  @Binding var rule: BookSearchRule
  var compact = false
  var canRemove = true
  var canAdd = true
  var onRemove: (() -> Void)? = nil
  var onAdd: (() -> Void)? = nil

  var body: some View {
    Group {
      if compact {
        VStack(spacing: 8) {
          HStack(spacing: 8) { fieldPicker; comparisonPicker; Spacer(minLength: 0); rowActions }
          valueEditor
        }
      } else {
        HStack(spacing: 10) { fieldPicker; comparisonPicker; valueEditor; rowActions }
      }
    }.onChange(of: rule.field) { _, field in
      rule.comparison = field.comparisons[0]
      rule.value = field.choices.first?.value ?? ""
    }
  }
  private var fieldPicker: some View {
    Picker("字段", selection: $rule.field) {
      ForEach(SearchBookField.allCases) { field in
        Text(field == .title ? "标题" : field.title).tag(field)
      }
    }.labelsHidden().frame(width: compact ? 118 : 180).accessibilityLabel("筛选字段")
      .help(rule.field == .title ? "标题包含副标题与原书名" : rule.field.title)
  }
  private var comparisonPicker: some View {
    Picker("比较方式", selection: $rule.comparison) {
      ForEach(rule.field.comparisons) { Text($0.title).tag($0) }
    }.labelsHidden().frame(width: compact ? 95 : 110).accessibilityLabel("比较方式")
  }
  @ViewBuilder private var valueEditor: some View {
    if rule.comparison.needsValue {
      if rule.field.choices.isEmpty {
        TextField("", text: $rule.value).textFieldStyle(.roundedBorder)
          .frame(maxWidth: .infinity).accessibilityLabel(rule.field == .title ? "标题条件值" : "\(rule.field.title)条件值")
          .help(rule.field.placeholder)
      } else {
        Picker("条件值", selection: $rule.value) {
          ForEach(rule.field.choices, id: \.value) { Text($0.title).tag($0.value) }
        }.labelsHidden().frame(maxWidth: .infinity).accessibilityLabel(rule.field == .title ? "标题条件值" : "\(rule.field.title)条件值")
      }
    } else {
      Text("无需填写值").font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }
  }
  @ViewBuilder private var rowActions: some View {
    if let onRemove, let onAdd {
      HStack(spacing: 4) {
        Button(action: onRemove) { Image(systemName: "minus.circle").frame(width: 20, height: 24) }
          .disabled(!canRemove).help("移除此条件").accessibilityLabel("移除此条件")
        Button(action: onAdd) { Image(systemName: "plus.circle").frame(width: 20, height: 24) }
          .disabled(!canAdd).help("在下方添加条件").accessibilityLabel("添加筛选条件")
      }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 16))
    }
  }
}

/// Lives above the results in the middle pane. Editing a draft never changes
/// the result set until Search is pressed; closing only collapses the controls.
struct InlineAdvancedSearchPanel: View {
  @Binding var query: AdvancedBookQuery
  let maximumRulesHeight: CGFloat
  let onSearch: () -> Void
  let onClear: () -> Void
  let onSave: () -> Void
  var smartName: Binding<String>? = nil
  var errorMessage: String? = nil
  var onCancel: (() -> Void)? = nil
  var isCreatingSmartCollection = false
  @State private var width: CGFloat = 700
  @FocusState private var smartNameFocused: Bool
  private var compact: Bool { width < 600 }
  private var canSearch: Bool { query.validationMessage == nil }
  private var isSimpleSavedSearch: Bool { query.savedSearch != nil && query.rules.isEmpty }
  private var canSave: Bool {
    canSearch && query.hasConditions && (smartName == nil || !smartName!.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
  private var showsValidation: Bool {
    query.rules.contains { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ||
      query.savedSearch?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let smartName {
        HStack(spacing: 10) {
          Text("智能文件夹").foregroundStyle(.secondary)
          TextField("文件夹名称", text: smartName).textFieldStyle(.roundedBorder)
            .focused($smartNameFocused)
            .accessibilityLabel(isCreatingSmartCollection ? "新建智能文件夹名称" : "编辑智能文件夹名称")
        }
      }
      HStack(spacing: 8) {
        Text(query.savedSearch == nil ? "查找全部书籍，匹配" : isSimpleSavedSearch ? "查找书库条目" : "在搜索结果中匹配")
        if !isSimpleSavedSearch {
          Picker("匹配方式", selection: $query.mode) {
            Text("全部条件").tag(SearchMatchMode.all)
            Text("任一条件").tag(SearchMatchMode.any)
          }.labelsHidden().frame(width: 110).accessibilityLabel("匹配方式")
        }
        Spacer(minLength: 0)
        Menu {
          Button("待补全 ISBN") { query = AdvancedBookQuery(rules: [BookSearchRule(field: .isbn, comparison: .isEmpty)]) }
          Button("有笔记的书") { query = AdvancedBookQuery(rules: [BookSearchRule(field: .notes, comparison: .isNotEmpty)]) }
        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .accessibilityLabel("常用筛选条件").help("常用筛选条件")
      }
      ScrollView {
        VStack(spacing: 6) {
          if query.savedSearch != nil { savedSearchRow }
          ForEach($query.rules) { $rule in
            SearchRuleRow(rule: $rule, compact: compact,
              canRemove: query.rules.count > 1 || query.savedSearch != nil,
              canAdd: query.rules.count < 50,
              onRemove: {
                query.rules.removeAll { $0.id == rule.id }
                if query.rules.isEmpty && query.savedSearch == nil { query.rules = [BookSearchRule()] }
              },
              onAdd: {
                guard let index = query.rules.firstIndex(where: { $0.id == rule.id }), query.rules.count < 50 else { return }
                query.rules.insert(BookSearchRule(), at: index + 1)
              })
              .padding(.horizontal, 8).padding(.vertical, 6)
              .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
              .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
          }
        }.padding(.vertical, 1)
      }.frame(height: min(maximumRulesHeight,
        CGFloat(max(1, query.rules.count + (query.savedSearch == nil ? 0 : 1))) * (compact ? 82 : 44)))
      if showsValidation, let message = query.validationMessage {
        Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
      if let errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 10) {
        if smartName == nil { searchButton.buttonStyle(.borderedProminent) }
        else { searchButton.buttonStyle(.bordered) }
        Button(smartName == nil ? "清除筛选" : "清空条件", action: onClear).buttonStyle(.bordered)
          .accessibilityLabel(smartName == nil ? "清除筛选" : "清空筛选条件")
        if let onCancel {
          Button("取消", action: onCancel).buttonStyle(.bordered)
            .accessibilityLabel(isCreatingSmartCollection ? "取消新建智能文件夹" : "取消编辑智能文件夹")
          Button(isCreatingSmartCollection ? "保存文件夹" : "保存修改", action: onSave).buttonStyle(.borderedProminent)
            .disabled(!canSave).accessibilityLabel(isCreatingSmartCollection ? "保存新智能文件夹" : "保存智能文件夹规则修改")
        } else {
          Button("保存为智能文件夹…", action: onSave).buttonStyle(.bordered)
            .disabled(!canSave).accessibilityLabel("保存筛选为智能文件夹")
        }
        Spacer(minLength: 0)
      }
    }.font(.system(size: 13)).padding(12)
      .background(Color(nsColor: .windowBackgroundColor))
      .background(GeometryReader { geometry in
        Color.clear.onAppear { width = geometry.size.width }
          .onChange(of: geometry.size.width) { _, value in width = value }
      })
      .onSubmit { if canSearch { onSearch() } }
      .onAppear { if isCreatingSmartCollection { smartNameFocused = true } }
      .accessibilityElement(children: .contain).accessibilityLabel("高级筛选条件面板")
  }

  private var searchButton: some View {
    Button("搜索", action: onSearch).disabled(!canSearch).accessibilityLabel("执行高级筛选")
  }

  /// Preserve the exact saved quick-search semantics (including standalone
  /// notes), rather than converting its keyword to a book-only rule.
  private var savedSearchRow: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        Picker("搜索范围", selection: Binding(get: { query.savedSearch?.scope ?? .fieldsAndTags },
          set: { query.savedSearch?.scope = $0 })) {
          ForEach((query.savedSearch?.scope ?? .fieldsAndTags).editingScopes) { scope in
            Text(scope.title).tag(scope)
          }
        }.labelsHidden().frame(width: compact ? 156 : 190).accessibilityLabel("已保存搜索范围")
        if compact { Spacer(minLength: 0) } else { savedSearchText }
        Button { query.rules.append(BookSearchRule()) } label: {
          Image(systemName: "plus.circle").frame(width: 20, height: 24)
        }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 16))
          .disabled(query.rules.count >= 50).help("添加附加筛选条件").accessibilityLabel("添加附加筛选条件")
      }
      if compact { savedSearchText }
    }.padding(.horizontal, 8).padding(.vertical, 6)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
  }

  private var savedSearchText: some View {
    TextField("", text: Binding(get: { query.savedSearch?.text ?? "" }, set: { query.savedSearch?.text = $0 }))
      .textFieldStyle(.roundedBorder).accessibilityLabel("已保存搜索关键词")
      .frame(maxWidth: .infinity)
  }
}
