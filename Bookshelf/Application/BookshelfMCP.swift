import CryptoKit
import Foundation
import Observation
import SwiftData

/// Each stdio connection negotiates its own session. Only bibliographic fields cross the boundary.
@MainActor
final class BookshelfMCPSession {
  typealias Object = [String: Any]
  private var initialized = false
  private var ready = false
  private let context: ModelContext
  private let submit: (MetadataUpdateProposal) throws -> Void

  init(context: ModelContext, submit: @escaping (MetadataUpdateProposal) throws -> Void) {
    self.context = context
    self.submit = submit
  }

  private static func input(_ properties: Object, required: [String]) -> Object {
    ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
  }
  private static let string = ["type": "string"]
  static var tools: [Object] {
    [
      ["name": "search_books", "description": "Find up to 20 active books by title or ISBN. Use get_book_metadata to inspect an edition.",
       "inputSchema": input(["query": string], required: ["query"])],
      ["name": "get_book_metadata", "description": "Read public bibliographic fields and revision for one book. Notes, attachments and organization are private.",
       "inputSchema": input(["book_id": string], required: ["book_id"])],
      ["name": "propose_metadata", "description": "Suggest known fields for the exact edition. Omit uncertain facts. Returns pending_review. Only the person in Bookshelf can apply changes.",
       "inputSchema": input(["book_id": string, "revision": string, "fields": AIMetadata.schema], required: ["book_id", "revision", "fields"])]
    ]
  }

  func respond(to data: Data) -> Data? {
    let reply: Object?
    if let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
      if let message = json as? Object { reply = handle(message) }
      else { reply = failure(NSNull(), -32600, "Invalid request") }
    } else { reply = failure(NSNull(), -32700, "Parse error") }
    return reply.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
  }

  private func failure(_ id: Any, _ code: Int, _ message: String) -> Object {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as Object]
  }

  private func handle(_ message: Object) -> Object? {
    let id = message["id"]
    guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
      return failure(id ?? NSNull(), -32600, "Invalid request")
    }
    guard let id else {
      if method == "notifications/initialized", initialized { ready = true }
      return nil
    }
    guard id is String || ((id as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true && id is Int)
    else { return failure(NSNull(), -32600, "Invalid id") }
    let params = message["params"] as? Object ?? [:]
    let result: Object
    switch method {
    case "initialize":
      guard !initialized, let requested = params["protocolVersion"] as? String,
        params["capabilities"] is Object, params["clientInfo"] is Object
      else { return failure(id, -32602, "Invalid initialization") }
      let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
      initialized = true
      result = ["protocolVersion": versions.contains(requested) ? requested : versions[0],
        "capabilities": ["tools": [:] as Object], "serverInfo": ["name": "Bookshelf", "version": AppReleaseInfo.version]]
    case "ping": result = [:]
    case "tools/list", "tools/call":
      guard ready else { return failure(id, -32002, "Initialize this connection first") }
      if method == "tools/list" { result = ["tools": Self.tools] }
      else {
        guard let name = params["name"] as? String, let args = params["arguments"] as? Object,
          Self.tools.contains(where: { $0["name"] as? String == name })
        else { return failure(id, -32602, "Unknown tool or invalid arguments") }
        do {
          let value = try call(name, args)
          let encoded = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
          result = ["content": [["type": "text", "text": String(decoding: encoded, as: UTF8.self)]]]
        } catch {
          result = ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]]
        }
      }
    default: return failure(id, -32601, "Method not found")
    }
    return ["jsonrpc": "2.0", "id": id, "result": result]
  }

  private func call(_ name: String, _ args: Object) throws -> Object {
    let invalid = AIMetadataError("Invalid tool arguments")
    if name == "search_books" {
      guard args.count == 1, let raw = args["query"] as? String else { throw invalid }
      let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !term.isEmpty, term.count <= 256 else { throw invalid }
      let isbn = ISBN.normalized(term) ?? ""
      var request = FetchDescriptor<Book>(predicate: #Predicate {
        $0.deletedAt == nil && ($0.title.localizedStandardContains(term) ||
          (!isbn.isEmpty && ($0.isbn10 == isbn || $0.isbn13 == isbn)))
      }, sortBy: [SortDescriptor(\Book.title)])
      request.fetchLimit = 20
      let matches: [Object] = try context.fetch(request).map { book in
        ["book_id": book.id.uuidString, "title": book.title, "authors": book.authors.map(\.name),
          "isbn": book.isbn13 ?? book.isbn10 ?? "", "publisher": book.publisher ?? "", "publicationDate": book.publicationDate ?? ""]
      }
      return ["books": matches]
    }
    guard let raw = args["book_id"] as? String, let id = UUID(uuidString: raw) else { throw invalid }
    let current = BookArchive(book: try AIMetadata.book(id, context: context))
    let fields = AIMetadata.publicFields(current)
    let encoded = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    let revision = Data(SHA256.hash(data: encoded)).base64EncodedString()
    if name == "get_book_metadata" {
      guard args.count == 1 else { throw invalid }
      return ["book_id": raw, "fields": fields, "revision": revision]
    }
    guard args.count == 3, let received = args["revision"] as? String, let values = args["fields"] as? Object else { throw invalid }
    guard revision == received else { throw AIMetadataError("The book changed. Read its metadata again.") }
    let proposal = try AIMetadata.proposal(values, current: current, source: "AI · MCP")
    try submit(proposal)
    return ["book_id": raw, "status": "pending_review"]
  }
}

@MainActor @Observable
final class AIMetadataWorkspace {
  static let enabledKey = "aiMetadata.mcpEnabled"
  let context: ModelContext
  let socket: LocalMCPSocket
  private(set) var pending: [MetadataUpdateProposal] = []
  private(set) var enabled = false
  private(set) var listening = false
  private(set) var error: String?
  private let defaults: UserDefaults

  init(context: ModelContext, defaults: UserDefaults = .standard, socket: LocalMCPSocket = LocalMCPSocket()) {
    self.context = context
    self.defaults = defaults
    self.socket = socket
    if defaults.bool(forKey: Self.enabledKey) { setEnabled(true) }
  }

  func setEnabled(_ value: Bool) {
    socket.stop()
    enabled = value
    listening = false
    error = nil
    defaults.set(value, forKey: Self.enabledKey)
    if !value { pending.removeAll(); return }
    do {
      try socket.start(makeSession: { [weak self, context] in
        BookshelfMCPSession(context: context) { [weak self] proposal in
          guard let self, self.enabled else { throw AIMetadataError("MCP disabled") }
          guard self.pending.count < 30, !self.pending.contains(where: { $0.current.id == proposal.current.id })
          else { throw AIMetadataError("Review pending suggestions in Bookshelf first.") }
          self.pending.append(proposal)
        }
      }, onState: { [weak self] result in
        self?.listening = result == nil
        if let result { self?.setEnabled(false); self?.error = result.localizedDescription }
      })
    } catch {
      setEnabled(false)
      self.error = error.localizedDescription
    }
  }

  func discard(_ id: UUID) { pending.removeAll { $0.id == id } }

  func accept(_ proposal: MetadataUpdateProposal, fields: Set<BookField>, undoManager: UndoManager?) throws {
    guard pending.contains(where: { $0.id == proposal.id }) else { throw BookMetadataEditError.conflict }
    try AIMetadata.apply(proposal, fields: fields, context: context, undoManager: undoManager)
    discard(proposal.id)
  }
}
