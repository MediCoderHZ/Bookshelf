import CoreTransferable
import Foundation
import UniformTypeIdentifiers

enum NoteDragTransfer {
  static let type = UTType(exportedAs: "org.bookshelf.note-drag", conformingTo: .data)
}

extension NoteDragBatch: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(contentType: NoteDragTransfer.type) { payload in
      try JSONEncoder().encode(payload)
    } importing: { data in
      try JSONDecoder().decode(NoteDragBatch.self, from: data)
    }
  }
}
