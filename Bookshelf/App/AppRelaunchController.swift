import AppKit
import Combine
import Darwin
import Foundation

enum AppRelaunchError: LocalizedError {
  case unavailable, notReady, terminationCancelled
  var errorDescription: String? {
    switch self {
    case .unavailable: L10n.tr("未找到重启组件，请重新安装应用后再试。")
    case .notReady: L10n.tr("无法准备自动重启，应用尚未退出，请重试。")
    case .terminationCancelled: L10n.tr("退出已取消，应用保持打开。请完成当前操作后再重试。")
    }
  }
}

@MainActor
protocol AppRelaunchSession: AnyObject {
  func waitUntilReady() async throws
  func arm() throws
  func cancel()
}

@MainActor
final class AppRelaunchController: ObservableObject {
  static let settingsRequestKey = "showSettingsAfterRelaunch"
  @Published private(set) var isRestarting = false
  @Published private(set) var errorMessage: String?
  private let prepare: () throws -> Void
  private let makeSession: () throws -> any AppRelaunchSession
  private let terminate: () -> Void
  private let setSettingsRequested: (Bool) -> Void
  private let waitForTermination: () async -> Void

  init(prepare: @escaping () throws -> Void,
    makeSession: @escaping () throws -> any AppRelaunchSession = { try AppRelaunchProcess() },
    terminate: @escaping () -> Void = { NSApp.terminate(nil) },
    setSettingsRequested: @escaping (Bool) -> Void = { UserDefaults.standard.set($0, forKey: AppRelaunchController.settingsRequestKey) },
    waitForTermination: @escaping () async -> Void = { try? await Task.sleep(for: .seconds(1)) }) {
    self.prepare = prepare; self.makeSession = makeSession
    self.terminate = terminate; self.waitForTermination = waitForTermination
    self.setSettingsRequested = setSettingsRequested
  }

  func restart() async {
    guard !isRestarting else { return }
    isRestarting = true; errorMessage = nil
    var session: (any AppRelaunchSession)?
    var settingsRequested = false
    defer {
      session?.cancel(); isRestarting = false
      if settingsRequested { setSettingsRequested(false) }
    }
    do {
      try prepare()
      let child = try makeSession(); session = child
      try await child.waitUntilReady()
      try child.arm()
      setSettingsRequested(true); settingsRequested = true
      terminate()
      // Successful normal termination ends this process. If it stays alive,
      // disarm the helper so a later ordinary quit cannot unexpectedly reopen it.
      await waitForTermination()
      throw AppRelaunchError.terminationCancelled
    } catch { errorMessage = L10n.tr("无法重启应用：\(error.localizedDescription)") }
  }
}

@MainActor
final class AppRelaunchProcess: AppRelaunchSession {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()

  init(bundle: Bundle = .main) throws {
    guard bundle.bundleURL.pathExtension == "app",
      let script = bundle.url(forResource: "relaunch", withExtension: "sh")
    else { throw AppRelaunchError.unavailable }
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), bundle.bundleURL.path]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
  }

  func waitUntilReady() async throws {
    let handle = output.fileHandleForReading
    let ready = await Task.detached {
      var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
      guard poll(&descriptor, 1, 3_000) > 0, descriptor.revents & Int16(POLLIN) != 0 else { return false }
      return (try? handle.read(upToCount: 6)) == Data("READY\n".utf8)
    }.value
    guard ready, process.isRunning else { throw AppRelaunchError.notReady }
  }
  func arm() throws {
    guard process.isRunning else { throw AppRelaunchError.notReady }
    try input.fileHandleForWriting.write(contentsOf: Data("RELAUNCH\n".utf8))
  }
  func cancel() {
    if process.isRunning { process.terminate() }
    try? input.fileHandleForWriting.close()
    try? output.fileHandleForReading.close()
  }
}
