import Foundation

/// Local navigation preferences, separate from the library's records and backups.
struct LibraryWorkspaceState: Codable, Equatable {
  static let storageKey = "libraryWorkspaceState.v1"
  var selection: LibrarySelection = .all
  var bookIDs: Set<UUID> = []
  var noteID: UUID?
  var trashBookIDs: Set<UUID> = []
  var trashNoteIDs: Set<UUID> = []
  var expandedBookIDs: Set<UUID> = []
  var expandedCollectionIDs: Set<UUID> = []
  var expandedPanels: Set<InspectorPanel> = [.info]
  var activePanel: InspectorPanel = .info

  static func load(from defaults: UserDefaults = .standard) -> Self {
    RetiredReadingData.cleanPreferences(defaults)
    guard let data = defaults.data(forKey: storageKey),
      let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
    return state
  }

  func save(to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }

  /// A deleted/moved item or a replaced library must not restore a dangling selection.
  func validated(books: [Book], collections: [BookCollection], notes: [NoteRecord],
    includeSubcollections: Bool) -> Self {
    var result = self
    switch selection {
    case .collection(let id):
      if !collections.contains(where: { $0.id == id && !$0.isSmart }) { result.selection = .all }
    case .smart(let id):
      if !collections.contains(where: { $0.id == id && $0.isSmart }) { result.selection = .all }
    case .recent, .notes, .standaloneNotes:
      // These navigation entries were removed; do not restore an invisible scope.
      result.selection = .all
    default: break
    }
    let isTrash = result.selection == .trash || result.selection == .noteTrash
    let visibleBooks = LibraryQueries.results(books, collections: collections,
      request: LibraryQueryRequest(selection: result.selection, includeSubcollections: includeSubcollections), notes: notes)
    let visibleIDs = Set(visibleBooks.map(\.id))
    let smart = collections.first { result.selection == .smart($0.id) }?.smartQuery
    let visibleNotes = NoteQueries.results(notes, books: books,
      collections: collections.filter { !$0.isSmart }.map(ManualCollectionRecord.init),
      scope: result.selection, text: "", includeSubcollections: includeSubcollections, smartQuery: smart)
    if isTrash {
      result.bookIDs = []; result.noteID = nil
      result.trashBookIDs.formIntersection(visibleIDs)
      result.trashNoteIDs.formIntersection(visibleNotes.map(\.id))
    } else {
      result.trashBookIDs = []; result.trashNoteIDs = []
      result.bookIDs.formIntersection(visibleIDs)
      if let id = result.noteID {
        let child = notes.first { $0.id == id && $0.deletedAt == nil && $0.parentBookID.map(visibleIDs.contains) == true }
        if !visibleNotes.contains(where: { $0.id == id }) && child == nil { result.noteID = nil }
        else {
          result.bookIDs = []
          if let parent = child?.parentBookID { result.expandedBookIDs.insert(parent) }
        }
      }
    }
    result.expandedBookIDs.formIntersection(books.map(\.id))
    result.expandedCollectionIDs.formIntersection(collections.filter { !$0.isSmart }.map(\.id))
    return result
  }
}
