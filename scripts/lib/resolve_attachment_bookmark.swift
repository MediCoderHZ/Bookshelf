import Foundation

// The installer runs outside the app. Resolve the stored directory bookmark
// with Foundation before opening any attachment on the user's behalf.
do {
  var stale = false
  let data = FileHandle.standardInput.readDataToEndOfFile()
  let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
    relativeTo: nil, bookmarkDataIsStale: &stale)
  let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
  guard url.isFileURL, values.isDirectory == true, values.isSymbolicLink != true else {
    throw CocoaError(.fileReadUnknown)
  }
  FileHandle.standardOutput.write(try JSONEncoder().encode(url.path))
} catch {
  FileHandle.standardError.write(Data("External attachment folder unavailable; installation stopped.\n".utf8))
  exit(1)
}
