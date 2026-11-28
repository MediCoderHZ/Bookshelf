import Foundation
import SwiftData
import XCTest
@testable import Bookshelf

@MainActor
final class AIMetadataTests: XCTestCase {
  typealias Object = [String: Any]

  func testReviewedAIFieldsStayInEditorDraftUntilSave() throws {
    let db = try LibraryDatabase.open(inMemory: true)
    let book = Book(title: "Saved title")
    db.mainContext.insert(book)
    try db.mainContext.save()
    let baseline = BookArchive(book: book)
    var draft = baseline
    draft.title = "Edited title"
    draft.publisher = "Edited imprint"
    draft = BookRecordMerge.markingManualChanges(draft, comparedTo: baseline)

    let proposal = try AIMetadata.proposal(["publisher": "Suggested imprint", "pageCount": 120],
      current: draft, source: "AI · test")
    XCTAssertEqual(proposal.current.title, "Edited title")
    XCTAssertEqual(proposal.defaultSelection, [.pageCount])
    let reviewed = BookRecordMerge.applyingMetadata(proposal.incoming, to: draft, fields: [.pageCount])
    XCTAssertEqual(BookArchive(book: book), baseline)

    try LibraryCommands(context: db.mainContext, undoManager: nil).save(reviewed, expected: baseline)
    XCTAssertEqual(book.title, "Edited title")
    XCTAssertEqual(book.publisher, "Edited imprint")
    XCTAssertEqual(book.pageCount, 120)
    let origins = BookRecordMerge.origins(BookArchive(book: book))
    XCTAssertEqual(origins["publisher"]?.name, "手动编辑")
    XCTAssertEqual(origins["pageCount"]?.name, "AI · test")
  }

  func testModelRequestAndReviewPreservePrivateContentAndUnselectedFields() throws {
    let db = try LibraryDatabase.open(inMemory: true)
    let book = Book(title: "An edition")
    book.publisher = "Existing imprint"
    book.notes = "PRIVATE NOTE"
    book.attachmentIDs = [UUID()]
    db.mainContext.insert(book)
    try db.mainContext.save()
    let baseline = BookArchive(book: book)
    let config = try AIModelConfiguration(base: "http://localhost:11434/v1/", model: "local-model")
    let request = try AIModelClient.request(for: baseline, configuration: config, key: "test-only")
    XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
    let body = try XCTUnwrap(request.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? Object)
    let messages = try XCTUnwrap(json["messages"] as? [[String:String]])
    let input = try XCTUnwrap(messages.last?["content"])
    XCTAssertFalse(input.contains("PRIVATE"))
    XCTAssertFalse(input.contains(book.attachmentIDs![0].uuidString))
    XCTAssertFalse(input.contains(book.id.uuidString))
    XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String:String],
      ["title":"An edition", "publisher":"Existing imprint"])
    let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content":
      #"{"publisher":"New imprint","pageCount":218,"authors":["Family, Given"]}"#]]]])
    let proposal = try AIModelClient.proposal(from: response, current: baseline, model: "local-model")
    XCTAssertEqual(proposal.defaultSelection, [.authors, .pageCount])
    XCTAssertNil(book.pageCount)
    try AIMetadata.apply(proposal, fields: [.pageCount], context: db.mainContext, undoManager: nil)
    XCTAssertEqual(book.pageCount, 218)
    XCTAssertEqual(book.publisher, "Existing imprint")
    XCTAssertEqual(book.notes, "PRIVATE NOTE")
    XCTAssertTrue(book.authors.isEmpty)
    XCTAssertEqual(BookRecordMerge.origins(BookArchive(book: book))["pageCount"]?.name, "AI · local-model")
  }

  func testInvalidFieldsChangesAndTrashCannotOverwriteData() throws {
    let db = try LibraryDatabase.open(inMemory: true)
    let book = Book(title: "First edition")
    db.mainContext.insert(book)
    try db.mainContext.save()
    let current = BookArchive(book: book)
    for values: Object in [["notes":"forbidden"], ["isbn":"1111111111111"], ["pageCount":true],
      ["authors":"Wrong type"], ["publisher":""], [:]] {
      XCTAssertThrowsError(try AIMetadata.proposal(values, current: current, source: "AI"))
    }
    let proposal = try AIMetadata.proposal(["publisher":"AI imprint"], current: current, source: "AI")
    book.publisher = "User edit"
    try db.mainContext.save()
    XCTAssertThrowsError(try AIMetadata.apply(proposal, fields: [.publisher], context: db.mainContext, undoManager: nil))
    XCTAssertEqual(book.publisher, "User edit")
    book.deletedAt = Date()
    try db.mainContext.save()
    XCTAssertThrowsError(try AIMetadata.book(book.id, context: db.mainContext))
    XCTAssertThrowsError(try AIModelConfiguration(base: "http://remote.example/v1", model: "m"))
    XCTAssertThrowsError(try AIModelConfiguration(base: "https://name:pass@remote.example/v1", model: "m"))
    XCTAssertThrowsError(try AIModelConfiguration(base: "https://remote.example/v1?key=secret", model: "m"))
  }

  func testLegacyAISuggestionsIgnoreDescriptionAndKeepSupportedFields() throws {
    let book = Book(title: "Title")
    book.bookDescription = "Existing description"
    let current = BookArchive(book: book)
    let properties = try XCTUnwrap(AIMetadata.schema["properties"] as? Object)
    XCTAssertNil(properties["description"])
    XCTAssertNil(AIMetadata.publicFields(current)["description"])

    let values = ["description": "New description", "publisher": "New publisher"]
    let proposal = try AIMetadata.proposal(values, current: current, source: "AI")
    XCTAssertEqual(proposal.defaultSelection, [.publisher])
    XCTAssertEqual(proposal.incoming.publisher, "New publisher")
    XCTAssertNil(proposal.incoming.bookDescription)
    XCTAssertThrowsError(try AIMetadata.proposal(["description": "New description"], current: current, source: "AI"))
  }

  func testExternalClientQueriesAndSubmitsOnlyForReview() throws {
    let db = try LibraryDatabase.open(inMemory: true)
    let book = Book(title: "Edition Test"), trashed = Book(title: "Edition Trashed")
    book.notes = "Never share this"
    book.isbn13 = "9780306406157"
    trashed.deletedAt = Date()
    db.mainContext.insert(book)
    db.mainContext.insert(trashed)
    try db.mainContext.save()
    var pending: [MetadataUpdateProposal] = []
    let session = BookshelfMCPSession(context: db.mainContext) { pending.append($0) }
    func rpc(_ method: String, _ params: Object = [:], id: Int? = 1) throws -> Object? {
      var message: Object = ["jsonrpc":"2.0", "method":method, "params":params]
      message["id"] = id
      let data = try JSONSerialization.data(withJSONObject: message)
      guard let result = session.respond(to: data) else { return nil }
      return try JSONSerialization.jsonObject(with: result) as? Object
    }
    func call(_ name: String, _ args: Object) throws -> Object {
      let response = try XCTUnwrap(try rpc("tools/call", ["name":name, "arguments":args])?["result"] as? Object)
      if response["isError"] as? Bool == true { return response }
      let items = try XCTUnwrap(response["content"] as? [[String:String]])
      return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(items.first?["text"]).utf8)) as? Object)
    }
    XCTAssertNotNil(try rpc("tools/list")?["error"])
    XCTAssertNotNil(try rpc("initialize", ["protocolVersion":"2025-11-25", "capabilities":Object(), "clientInfo":["name":"test", "version":"1"]])?["result"])
    XCTAssertNil(try rpc("notifications/initialized", id:nil))
    let list = try XCTUnwrap(try rpc("tools/list")?["result"] as? Object)
    XCTAssertEqual((list["tools"] as? [Object])?.count, 3)
    let search = try call("search_books", ["query":"Edition"])
    XCTAssertEqual((search["books"] as? [Object])?.count, 1)
    let metadata = try call("get_book_metadata", ["book_id":book.id.uuidString])
    let revision = try XCTUnwrap(metadata["revision"] as? String)
    let fields = try XCTUnwrap(metadata["fields"] as? Object)
    XCTAssertNil(fields["notes"])
    XCTAssertEqual(try call("get_book_metadata", ["book_id":trashed.id.uuidString])["isError"] as? Bool, true)
    let args: Object = ["book_id":book.id.uuidString, "revision":revision, "fields":["publisher":"MCP imprint"]]
    XCTAssertEqual(try call("propose_metadata", args)["status"] as? String, "pending_review")
    XCTAssertEqual(pending.count, 1)
    XCTAssertNil(book.publisher)
    try AIMetadata.apply(pending[0], fields: [.publisher], context: db.mainContext, undoManager: nil)
    XCTAssertEqual(book.publisher, "MCP imprint")
    XCTAssertEqual(try call("propose_metadata", args)["isError"] as? Bool, true)
  }

  func testMacOSStdioClientConnectsToPrivateSocket() async throws {
    let db = try LibraryDatabase.open(inMemory: true)
    let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("bookshelf-mcp-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "bookshelf-mcp-tests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let socket = LocalMCPSocket(directory: directory)
    let workspace = AIMetadataWorkspace(context: db.mainContext, defaults: defaults, socket: socket)
    XCTAssertFalse(workspace.enabled)
    workspace.setEnabled(true)
    defer { workspace.setEnabled(false) }
    for _ in 0..<100 where !workspace.listening && workspace.error == nil { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertTrue(workspace.listening, workspace.error ?? "")
    let path = socket.path
    let transcript = try await Task.detached {
      let process = Process(), input = Pipe(), output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
      process.arguments = ["-w", "4", "-U", path]
      process.standardInput = input
      process.standardOutput = output
      try process.run()
      let messages = """
        {"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1"},"capabilities":{}}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","method":"tools/list","id":2}

        """
      try input.fileHandleForWriting.write(contentsOf: Data(messages.utf8))
      try input.fileHandleForWriting.close()
      let data = try output.fileHandleForReading.readToEnd() ?? Data()
      process.waitUntilExit()
      return String(decoding: data, as: UTF8.self)
    }.value
    XCTAssertTrue(transcript.contains("propose_metadata"), transcript)
    workspace.setEnabled(false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }
}

private final class MockCatalogModel: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let status = request.url?.path == "/v1/chat/completions" && request.httpMethod == "POST"
      && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only" ? 200 : 401
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type":"application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"{\"publisher\":\"Test Press\"}"}}]}"#.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

extension AIMetadataTests {
  func testModelHTTPCompletionReturnsSuggestionWithoutSavingAndReportsUnauthorized() async throws {
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [MockCatalogModel.self]
    let config = try AIModelConfiguration(base: "https://catalog.invalid/v1", model: "test")
    let book = Book(title: "Fixture")
    let record = BookArchive(book: book)
    let proposal = try await AIModelClient.complete(record, configuration: config, key: "test-only", settings: settings)
    XCTAssertEqual(proposal.incoming.publisher, "Test Press")
    XCTAssertNil(book.publisher)
    do {
      _ = try await AIModelClient.complete(record, configuration: config, key: nil, settings: settings)
      XCTFail("Expected HTTP 401")
    } catch BookMetadataError.httpStatus(let status) { XCTAssertEqual(status, 401) }
  }
}
