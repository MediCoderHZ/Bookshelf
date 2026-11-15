import Foundation
import SwiftData

@MainActor
enum LibraryOrganization {
  static func setMembership(
    of book: Book, in collection: BookCollection, included: Bool, context: ModelContext
  ) {
    guard !collection.isSmart else { return }
    let links = book.collectionItems.filter { $0.collection?.id == collection.id }
    if included && links.isEmpty {
      context.insert(CollectionItem(collection: collection, book: book))
    } else if !included {
      for link in links {
        book.collectionItems.removeAll { $0.id == link.id }
        collection.items.removeAll { $0.id == link.id }
        context.delete(link)
      }
    }
  }
}
