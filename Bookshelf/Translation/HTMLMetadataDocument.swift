import Foundation
// libxml2 exposes a shared allocator pointer, which this app never changes.
@preconcurrency import libxml2

/// libxml2 parses inert HTML locally. NONET prevents external resource resolution.
/// Each document owns its nodes and XPath contexts and stays within one synchronous parse.
final class HTMLMetadataDocument {
  private let document: htmlDocPtr
  private let context: xmlXPathContextPtr

  init(data: Data) throws {
    guard data.count <= WebMetadataClient.htmlLimit else { throw WebMetadataError.tooLarge }
    let options = HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NONET.rawValue
      | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
    guard !data.isEmpty, let doc = data.withUnsafeBytes({ buffer in
      htmlReadMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count), nil, "UTF-8", Int32(options))
    }) else { throw WebMetadataError.noBook }
    guard let ctx = xmlXPathNewContext(doc) else {
      xmlFreeDoc(doc)
      throw WebMetadataError.noBook
    }
    document = doc
    context = ctx
  }

  deinit { xmlXPathFreeContext(context); xmlFreeDoc(document) }

  func nodes(_ xpath: String, from node: xmlNodePtr? = nil) -> [xmlNodePtr] {
    context.pointee.node = node ?? xmlDocGetRootElement(document)
    guard let result = xmlXPathEvalExpression(xpath, context) else { return [] }
    defer { xmlXPathFreeObject(result) }
    guard let set = result.pointee.nodesetval, let table = set.pointee.nodeTab,
      set.pointee.nodeNr > 0 else { return [] }
    return (0..<Int(set.pointee.nodeNr)).compactMap { table[$0] }
  }

  func first(_ xpath: String, from node: xmlNodePtr? = nil) -> xmlNodePtr? {
    nodes(xpath, from: node).first
  }

  func text(_ xpath: String) -> String? { first(xpath).flatMap { text(of: $0).nilIfBlank } }

  func text(of node: xmlNodePtr) -> String {
    clean(rawText(of: node))
  }

  // Embedded JSON must retain its whitespace and escape sequences.
  func rawText(of node: xmlNodePtr) -> String {
    guard let content = xmlNodeGetContent(node) else { return "" }
    defer { xmlFree(content) }
    return String(cString: content)
  }

  func attribute(_ name: String, of node: xmlNodePtr?) -> String? {
    guard let node, let value = xmlGetProp(node, name) else { return nil }
    defer { xmlFree(value) }
    return clean(String(cString: value))
  }

  func lines(of node: xmlNodePtr) -> [String] {
    var output = ""
    func walk(_ node: xmlNodePtr) {
      let name = node.pointee.name.map { String(cString: $0).lowercased() } ?? ""
      if ["script", "style"].contains(name) { return }
      if name == "br" { output += "\n"; return }
      if node.pointee.type == XML_TEXT_NODE || node.pointee.type == XML_CDATA_SECTION_NODE {
        output += text(of: node) + " "
        return
      }
      if ["p", "div"].contains(name) { output += "\n" }
      var child = node.pointee.children
      while let current = child { walk(current); child = current.pointee.next }
      if ["p", "div"].contains(name) { output += "\n" }
    }
    walk(node)
    return output.components(separatedBy: "\n").compactMap { clean($0).nilIfBlank }
  }

  static func validateXPath(_ expression: String) -> Bool {
    guard !expression.isEmpty, expression.count <= 2_048,
      let compiled = xmlXPathCompile(expression) else { return false }
    defer { xmlXPathFreeCompExpr(compiled) }
    guard let sample = try? HTMLMetadataDocument(data: Data("<html><body></body></html>".utf8)),
      let result = xmlXPathCompiledEval(compiled, sample.context) else { return false }
    defer { xmlXPathFreeObject(result) }
    return result.pointee.type == XPATH_NODESET
  }

  private func clean(_ value: String) -> String {
    value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
  }
}


private extension String {
  var nilIfBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
