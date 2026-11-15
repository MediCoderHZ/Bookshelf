import Foundation

struct NameSuggestion: Identifiable, Equatable {
  let name: String
  var id: String { name }
}

struct NameSuggestionSelection {
  enum Direction { case up, down }
  private(set) var selectedID: String?
  private(set) var isDismissed = false
  mutating func reset() { selectedID = nil; isDismissed = false }
  mutating func dismiss() { selectedID = nil; isDismissed = true }

  @discardableResult
  mutating func move(_ direction: Direction, in suggestions: [NameSuggestion]) -> Bool {
    guard !suggestions.isEmpty else { return false }
    isDismissed = false
    if let index = suggestions.firstIndex(where: { $0.id == selectedID }) {
      let next = direction == .down ? min(index + 1, suggestions.count - 1) : max(index - 1, 0)
      selectedID = suggestions[next].id
    } else { selectedID = (direction == .down ? suggestions.first : suggestions.last)?.id }
    return true
  }
  func selected(in suggestions: [NameSuggestion]) -> NameSuggestion? {
    guard !isDismissed else { return nil }
    return suggestions.first { $0.id == selectedID }
  }
}
