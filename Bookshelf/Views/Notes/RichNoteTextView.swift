import AppKit

/// A genuinely editable attributed document. Markdown markers are consumed by
/// input rules, and each conversion is independently undoable.
final class RichNoteTextView: NSTextView {
  struct Snapshot {
    let text: NSAttributedString
    let selection: NSRange
    let typing: [NSAttributedString.Key: Any]
    let source: String
  }
  private let history = UndoManager()
  private var ownedStorage: NSTextStorage?
  override var undoManager: UndoManager? { history }
  private var beforeInput: Snapshot?
  private var restoring = false
  private(set) var source = ""
  var onChange: ((String) -> Void)?
  var onSelectionChange: (() -> Void)?
  var pendingFocus = false

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
    let storage = container == nil ? NSTextStorage() : nil
    let layout = NSLayoutManager()
    let resolved = container ?? NSTextContainer(size: NSSize(width: max(1, frameRect.width), height: CGFloat.greatestFiniteMagnitude))
    if let storage { storage.addLayoutManager(layout); layout.addTextContainer(resolved) }
    super.init(frame: frameRect, textContainer: resolved)
    ownedStorage = storage
    history.groupsByEvent = false
    isRichText = true; allowsUndo = false; importsGraphics = false
    isAutomaticQuoteSubstitutionEnabled = false; isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false; isAutomaticLinkDetectionEnabled = false
    usesFontPanel = false; usesRuler = false
    typingAttributes = RichNoteCodec.attributes()
    backgroundColor = .textBackgroundColor
    textContainerInset = NSSize(width: 10, height: 12)
    minSize = .zero; maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    isVerticallyResizable = true; isHorizontallyResizable = false; autoresizingMask = [.width]
    self.textContainer?.widthTracksTextView = true
    setAccessibilityLabel(L10n.tr("笔记正文"))
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func load(_ markdown: String) {
    let document = RichNoteCodec.decode(markdown)
    restoring = true
    textStorage?.setAttributedString(document.text)
    source = markdown
    setSelectedRange(NSRange(location: 0, length: 0))
    typingAttributes = document.text.length > 0 ? document.text.attributes(at: 0, effectiveRange: nil) : document.trailingAttributes
    restoring = false; beforeInput = nil; history.removeAllActions()
  }
  /// Restore without publishing a text edit, adding undo history or revealing the caret.
  func restoreEditorSelection(_ range: NSRange) {
    setSelectedRange(range)
    let length = attributedString().length
    if range.location < length {
      typingAttributes = attributedString().attributes(at: range.location, effectiveRange: nil)
    } else {
      typingAttributes = RichNoteCodec.decode(source).trailingAttributes
    }
  }
  private func snapshot(canonical: Bool = false) -> Snapshot {
    let text = NSAttributedString(attributedString: attributedString())
    return Snapshot(text: text, selection: selectedRange(), typing: typingAttributes,
      source: canonical ? RichNoteCodec.markdown(text, trailing: typingAttributes) : source)
  }
  private func remember(_ previous: Snapshot, name: String) {
    history.beginUndoGrouping()
    history.registerUndo(withTarget: self) { target in target.restore(previous) }
    history.setActionName(name); history.endUndoGrouping()
  }
  private func restore(_ previous: Snapshot) {
    let inverse = snapshot()
    history.registerUndo(withTarget: self) { target in target.restore(inverse) }
    restoring = true; beforeInput = nil
    textStorage?.setAttributedString(previous.text)
    setSelectedRange(previous.selection); typingAttributes = previous.typing
    source = previous.source; restoring = false
    notifyNativeChange(); onChange?(source); onSelectionChange?()
  }
  private func publish() {
    source = RichNoteCodec.markdown(attributedString(), trailing: typingAttributes)
    onChange?(source); onSelectionChange?()
  }
  override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
    history.disableUndoRegistration()
    defer { history.enableUndoRegistration() }
    guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
    if !restoring && beforeInput == nil { beforeInput = snapshot() }
    return true
  }
  override func didChangeText() {
    notifyNativeChange()
    guard !restoring else { return }
    if let before = beforeInput { remember(before, name: L10n.tr("输入笔记")); beforeInput = nil }
    if !hasMarkedText() { convertMarkdownAtCaret() }
    publish()
  }
  private func notifyNativeChange() {
    history.disableUndoRegistration()
    super.didChangeText()
    history.enableUndoRegistration()
  }
  override func unmarkText() {
    let wasComposing = hasMarkedText()
    super.unmarkText()
    guard wasComposing, !restoring else { return }
    convertMarkdownAtCaret(); publish()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if pendingFocus, let window { pendingFocus = false; window.makeFirstResponder(self) }
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers == .command {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "b": apply(.bold); return true
      case "i": apply(.italic); return true
      case "z": history.undo(); return true
      default: break
      }
    }
    if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" { history.redo(); return true }
    return super.performKeyEquivalent(with: event)
  }
  override func paste(_ sender: Any?) {
    guard let value = NSPasteboard.general.string(forType: .string) else { return }
    insertMarkdown(value)
  }
  override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
  override func pasteAsRichText(_ sender: Any?) { paste(sender) }
  func insertMarkdown(_ value: String) {
    let range = selectedRange()
    let line = paragraph(at: range.location)
    let document: RichNoteCodec.Document
    let current = block(at: range.location)
    if current.kind == "code" {
      document = RichNoteCodec.Document(text: NSAttributedString(string: value, attributes: RichNoteCodec.attributes(current)),
        trailingAttributes: RichNoteCodec.attributes(current))
    } else if !value.contains("\n"), current.kind != "plain" || (line.length > 0 && range != line) {
      document = RichNoteCodec.Document(text: RichNoteCodec.inline(value, block: current), trailingAttributes: RichNoteCodec.attributes(current))
    } else { document = RichNoteCodec.decode(value) }
    change(L10n.tr("粘贴笔记")) {
      self.textStorage?.replaceCharacters(in: range, with: document.text)
      self.setSelectedRange(NSRange(location: range.location + document.text.length, length: 0))
      self.typingAttributes = document.trailingAttributes
    }
  }
  private func change(_ name: String, _ operation: () -> Void) {
    if hasMarkedText() { unmarkText() }
    let previous = snapshot()
    beforeInput = nil; operation()
    remember(previous, name: name)
    notifyNativeChange(); publish()
  }
  private func paragraph(at location: Int) -> NSRange {
    let text = string as NSString
    var range = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
    if range.length > 0, text.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == "\n" { range.length -= 1 }
    return range
  }
  private func block(at location: Int) -> RichNoteBlock {
    let range = paragraph(at: location)
    return RichNoteBlock(attributes: range.location < (textStorage?.length ?? 0)
      ? textStorage!.attributes(at: range.location, effectiveRange: nil) : typingAttributes)
  }
  func apply(_ format: NoteMarkdownFormat) {
    window?.makeFirstResponder(self)
    switch format {
    case .bold: toggleInline(.noteBold)
    case .italic: toggleInline(.noteItalic)
    case .strike: toggleInline(.noteStrike)
    case .code: toggleInline(.noteInlineCode)
    case .link: break // The inline link popover supplies an actual destination.
    default:
      var value = RichNoteBlock()
      switch format {
      case .heading(let level): value.kind = level == 0 ? "plain" : "heading"; value.level = max(1, level)
      case .bullet: value.kind = "bullet"
      case .ordered: value.kind = "ordered"
      case .task: value.kind = "task"
      case .quote: value.kind = "quote"
      case .codeBlock: value.kind = "code"
      default: break
      }
      setBlock(value)
    }
  }
  private func toggleInline(_ key: NSAttributedString.Key) {
    let range = selectedRange()
    if range.length == 0 {
      var inline = typingAttributes
      inline[key] = !(inline[key] as? Bool == true)
      typingAttributes = RichNoteCodec.attributes(RichNoteBlock(attributes: inline), inline: inline)
      return
    }
    let copy = attributedString().attributedSubstring(from: range)
    var enabled = false
    copy.enumerateAttribute(key, in: NSRange(location: 0, length: copy.length)) { value, _, _ in
      if value as? Bool != true { enabled = true }
    }
    change(L10n.tr("笔记格式")) {
      copy.enumerateAttributes(in: NSRange(location: 0, length: copy.length)) { attrs, part, _ in
        var semantic = attrs; semantic[key] = enabled
        self.textStorage?.setAttributes(RichNoteCodec.attributes(RichNoteBlock(attributes: attrs), inline: semantic),
          range: NSRange(location: range.location + part.location, length: part.length))
      }
      self.setSelectedRange(range)
      self.typingAttributes = RichNoteCodec.attributes(self.block(at: NSMaxRange(range)))
    }
  }
  func setLink(_ destination: String?, range: NSRange, label: String) {
    guard range.location <= (textStorage?.length ?? 0), NSMaxRange(range) <= (textStorage?.length ?? 0) else { return }
    let link = destination.flatMap(RichNoteCodec.safeLink)
    change(L10n.tr("笔记链接")) {
      let base = self.block(at: range.location)
      if range.length == 0 {
        let text = label.isEmpty ? (destination ?? L10n.tr("链接")) : label
        var attrs = RichNoteCodec.attributes(base); attrs[.link] = link
        if link != nil { attrs[.foregroundColor] = NSColor.linkColor }
        self.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
        self.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
      } else if let link {
        self.textStorage?.addAttributes([.link: link, .noteLinkDestination: link.absoluteString, .foregroundColor: NSColor.linkColor], range: range)
      } else {
        self.textStorage?.removeAttribute(.link, range: range)
        self.textStorage?.removeAttribute(.noteLinkDestination, range: range)
        self.textStorage?.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
      }
      self.typingAttributes = RichNoteCodec.attributes(base)
    }
  }
  func setBlock(_ value: RichNoteBlock) {
    let selection = selectedRange(), text = string as NSString
    let end = selection.length == 0 ? selection.location : max(selection.location, NSMaxRange(selection) - 1)
    var ranges: [NSRange] = [], current = paragraph(at: selection.location)
    ranges.append(current)
    while NSMaxRange(current) < end && NSMaxRange(current) < text.length {
      current = paragraph(at: NSMaxRange(current) + 1); ranges.append(current)
    }
    change(L10n.tr("段落格式")) {
      var selectedStart = selection.location, selectedLength = selection.length
      for (offset, range) in ranges.enumerated().reversed() {
        var target = value
        if target.kind == "ordered" { target.ordinal += offset }
        let previous = self.block(at: range.location), raw = (self.string as NSString).substring(with: range)
        let prefixLength = raw.hasPrefix(previous.prefix) ? (previous.prefix as NSString).length : 0
        let contentRange = NSRange(location: range.location + prefixLength, length: range.length - prefixLength)
        let content = NSMutableAttributedString(attributedString: self.attributedString().attributedSubstring(from: contentRange))
        let copy = NSAttributedString(attributedString: content)
        copy.enumerateAttributes(in: NSRange(location: 0, length: copy.length)) { attrs, part, _ in
          content.setAttributes(RichNoteCodec.attributes(target, inline: attrs), range: part)
        }
        let replacement = NSMutableAttributedString(string: target.prefix, attributes: RichNoteCodec.attributes(target))
        replacement.append(content)
        self.textStorage?.replaceCharacters(in: range, with: replacement)
        let delta = replacement.length - range.length
        if range.location <= selectedStart { selectedStart = max(range.location + (target.prefix as NSString).length, selectedStart + delta) }
        else { selectedLength += delta }
      }
      let length = self.textStorage?.length ?? 0
      self.setSelectedRange(NSRange(location: min(selectedStart, length), length: min(max(0, selectedLength), max(0, length - selectedStart))))
      self.typingAttributes = RichNoteCodec.attributes(value)
    }
  }
  override func insertNewline(_ sender: Any?) {
    if hasMarkedText() { super.insertNewline(sender); return }
    let selection = selectedRange(), line = paragraph(at: selection.location)
    let current = block(at: selection.location), raw = (string as NSString).substring(with: line)
    if (current.isList || current.kind == "quote" || current.kind == "code"), raw == current.prefix {
      change(L10n.tr("结束段落格式")) {
        self.textStorage?.replaceCharacters(in: line, with: NSAttributedString(string: ""))
        self.setSelectedRange(NSRange(location: line.location, length: 0))
        self.typingAttributes = RichNoteCodec.attributes()
      }
      return
    }
    // A fence followed by Return begins a native code paragraph.
    if current.kind == "plain", RichNoteCodec.captures(#"^(`{3,}|~{3,})([^`~]*)$"#, raw) != nil {
      let match = RichNoteCodec.captures(#"^(`{3,}|~{3,})([^`~]*)$"#, raw)!
      var code = RichNoteBlock("code"); code.language = match[2]
      change(L10n.tr("Markdown 代码块")) {
        self.textStorage?.replaceCharacters(in: line, with: NSAttributedString(string: ""))
        self.setSelectedRange(NSRange(location: line.location, length: 0)); self.typingAttributes = RichNoteCodec.attributes(code)
      }
      return
    }
    if current.kind == "plain", RichNoteCodec.parseLine(raw).0.kind == "rule" {
      change(L10n.tr("Markdown 分隔线")) {
        let rule = RichNoteBlock("rule")
        self.textStorage?.replaceCharacters(in: line, with: NSAttributedString(string: "────────\n", attributes: RichNoteCodec.attributes(rule)))
        self.setSelectedRange(NSRange(location: line.location + 9, length: 0))
        self.typingAttributes = RichNoteCodec.attributes()
      }
      return
    }
    var next = current
    if current.kind == "heading" || current.kind == "rule" { next = RichNoteBlock() }
    if current.kind == "ordered" { next.ordinal += 1 }
    if current.kind == "task" { next.checked = false }
    change(L10n.tr("换行")) {
      let newline = NSMutableAttributedString(string: "\n", attributes: RichNoteCodec.attributes(current))
      newline.append(NSAttributedString(string: next.prefix, attributes: RichNoteCodec.attributes(next)))
      self.textStorage?.replaceCharacters(in: selection, with: newline)
      let tailLength = max(0, NSMaxRange(line) - NSMaxRange(selection))
      let tailRange = NSRange(location: selection.location + newline.length, length: tailLength)
      if tailLength > 0 {
        let tail = self.attributedString().attributedSubstring(from: tailRange)
        tail.enumerateAttributes(in: NSRange(location: 0, length: tail.length)) { attrs, range, _ in
          self.textStorage?.setAttributes(RichNoteCodec.attributes(next, inline: attrs),
            range: NSRange(location: tailRange.location + range.location, length: range.length))
        }
      }
      self.setSelectedRange(NSRange(location: selection.location + newline.length, length: 0))
      self.typingAttributes = RichNoteCodec.attributes(next)
    }
  }
  override func deleteBackward(_ sender: Any?) {
    let selection = selectedRange(), line = paragraph(at: selectedRange().location)
    let current = block(at: selection.location)
    if !hasMarkedText(), selection.length == 0, current.kind != "plain",
      selection.location == line.location + (current.prefix as NSString).length {
      setBlock(RichNoteBlock()); return
    }
    super.deleteBackward(sender)
  }
  private func convertMarkdownAtCaret() {
    let selection = selectedRange()
    guard selection.length == 0 else { return }
    let line = paragraph(at: selection.location), current = block(at: selection.location)
    guard current.kind != "code", current.kind != "rule" else { return }
    let raw = (string as NSString).substring(with: line)
    let caret = selection.location - line.location
    if caret == (raw as NSString).length {
      let parsed = RichNoteCodec.parseLine(raw)
      var target = parsed.0
      var recognized = current.kind == "plain" && target.kind != "plain" && target.kind != "rule" && parsed.1.isEmpty
      if current.kind == "bullet", ["•\t[ ] ", "•\t[x] ", "•\t[X] "].contains(raw) {
        target = RichNoteBlock("task"); target.checked = raw.lowercased().contains("[x]"); recognized = true
      }
      if recognized {
        let previous = snapshot(canonical: true)
        let visible = target.kind == "rule" ? "────────" : target.prefix
        textStorage?.replaceCharacters(in: line, with: NSAttributedString(string: visible, attributes: RichNoteCodec.attributes(target)))
        setSelectedRange(NSRange(location: line.location + (visible as NSString).length, length: 0))
        typingAttributes = RichNoteCodec.attributes(target)
        remember(previous, name: L10n.tr("Markdown 自动格式")); return
      }
    }
    let prefix = (raw as NSString).substring(to: min(caret, (raw as NSString).length))
    // Require completed markers at the caret; plain punctuation and partial input stay literal.
    let patterns = [#"(?<!\\)(\*\*|__)(?=\S)(.+?\S|\S)\1$"#,
      #"(?<![\\*])\*(?!\*)(?=\S)([^*\n]*\S)\*(?!\*)$"#,
      #"(?<![\\_])_(?!_)(?=\S)([^_\n]*\S)_(?!_)$"#,
      #"(?<!\\)~~(?=\S)(.+?\S|\S)~~$"#, #"(?<![\\`])`([^`\n]+)`$"#,
      #"(?<![\\!])\[([^\]\n]+)\]\(([^)\s]+)\)$"#]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else { continue }
      let range = NSRange(location: line.location + match.range.location, length: match.range.length)
      // Do not reinterpret literal delimiters inside an already formatted code span.
      if textStorage?.attribute(.noteInlineCode, at: range.location, effectiveRange: nil) as? Bool == true { return }
      let markdown = (string as NSString).substring(with: range)
      let replacement = RichNoteCodec.inline(markdown, block: current)
      guard replacement.string != markdown else { continue }
      let previous = snapshot(canonical: true)
      textStorage?.replaceCharacters(in: range, with: replacement)
      setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
      typingAttributes = RichNoteCodec.attributes(current)
      remember(previous, name: L10n.tr("Markdown 自动格式")); return
    }
  }
}
