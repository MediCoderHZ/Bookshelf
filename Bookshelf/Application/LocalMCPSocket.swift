import Darwin
import Foundation
import Network

/// macOS nc bridges client stdio to this private Unix socket. No TCP listener or separate app is needed.
@MainActor
final class LocalMCPSocket {
  let directory: URL
  var path: String { directory.appendingPathComponent("stdio").path }
  private var listener: NWListener?
  private var peers: [UUID: MCPPeer] = [:]
  private var lockFD: Int32 = -1
  private var boundPath: String?

  init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("BookshelfMCP", isDirectory: true)) {
    self.directory = directory
  }

  func start(makeSession: @escaping @MainActor () -> BookshelfMCPSession,
    onState: @escaping @MainActor (Error?) -> Void) throws {
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(),
      (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o077) == 0
    else { throw POSIXError(.EACCES) }
    let fd = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(.EACCES) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
    lockFD = fd
    do {
      // The client path remains stable; a cancelled listener cannot remove its successor's socket.
      let name = "s-" + UUID().uuidString.prefix(8)
      let target = directory.appendingPathComponent(name).path
      guard target.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw POSIXError(.ENAMETOOLONG) }
      for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix("s-") || url.lastPathComponent == "stdio" {
        try files.removeItem(at: url)
      }
      let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
      parameters.requiredLocalEndpoint = .unix(path: target)
      let server = try NWListener(using: parameters)
      listener = server
      boundPath = target
      server.stateUpdateHandler = { [weak self, weak server] state in
        MainActor.assumeIsolated {
          guard let self, let server, self.listener === server else { return }
          switch state {
          case .ready:
            do {
              try FileManager.default.createSymbolicLink(atPath: self.path, withDestinationPath: name)
              onState(nil)
            } catch { onState(error) }
          case .failed(let error): onState(error)
          default: break
          }
        }
      }
      server.newConnectionHandler = { [weak self, weak server] connection in
        MainActor.assumeIsolated {
          guard let self, let server, self.listener === server, self.peers.count < 12 else { connection.cancel(); return }
          let id = UUID()
          let peer = MCPPeer(connection: connection, session: makeSession()) { [weak self] in self?.peers[id] = nil }
          self.peers[id] = peer
          peer.start()
        }
      }
      server.start(queue: .main)
    } catch { stop(); throw error }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    let previous = peers
    peers.removeAll()
    for peer in previous.values { peer.stop() }
    if lockFD >= 0 {
      unlink(path)
      if let boundPath { unlink(boundPath) }
      boundPath = nil
      close(lockFD)
      lockFD = -1
    }
  }
}

@MainActor
private final class MCPPeer {
  let connection: NWConnection
  let session: BookshelfMCPSession
  let onClose: () -> Void
  private var buffer = Data()
  private var closed = false

  init(connection: NWConnection, session: BookshelfMCPSession, onClose: @escaping () -> Void) {
    self.connection = connection
    self.session = session
    self.onClose = onClose
  }
  func start() {
    connection.start(queue: .main)
    receive()
  }
  func stop() {
    guard !closed else { return }
    closed = true
    connection.cancel()
    onClose()
  }
  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, eof, error in
      MainActor.assumeIsolated { self?.process(data, eof: eof || error != nil) }
    }
  }
  private func process(_ data: Data?, eof: Bool) {
    guard !closed else { return }
    if let data { buffer.append(data) }
    var replies = Data()
    while let end = buffer.firstIndex(of: 10) {
      let line = buffer[..<end]
      guard line.count <= 65_536 else { stop(); return }
      if !line.isEmpty, let reply = session.respond(to: Data(line)) {
        replies.append(reply)
        replies.append(10)
      }
      buffer.removeSubrange(...end)
    }
    guard buffer.count <= 65_536 else { stop(); return }
    if replies.isEmpty {
      if eof { stop() } else { receive() }
    } else {
      connection.send(content: replies, completion: .contentProcessed { [weak self] error in
        MainActor.assumeIsolated {
          guard let self, !self.closed else { return }
          if error != nil || eof { self.stop() } else { self.receive() }
        }
      })
    }
  }
}
