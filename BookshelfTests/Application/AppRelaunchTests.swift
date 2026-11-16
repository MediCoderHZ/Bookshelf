import AppKit
import XCTest
@testable import Bookshelf

@MainActor
final class AppRelaunchTests: XCTestCase {
  private final class Session: AppRelaunchSession {
    var events: [String] = []
    var readinessError: Error?
    var suspendReadiness = false
    var continuation: CheckedContinuation<Void, Never>?
    func waitUntilReady() async throws {
      events.append("ready")
      if let readinessError { throw readinessError }
      if suspendReadiness { await withCheckedContinuation { continuation = $0 } }
    }
    func arm() throws { events.append("arm") }
    func cancel() { events.append("cancel") }
  }

  func testFailedPreparationKeepsApplicationOpenWithoutStartingHelper() async {
    var created = false, terminated = false
    let controller = AppRelaunchController(prepare: { throw AutomaticBackupError.pendingChanges },
      makeSession: { created = true; return Session() }, terminate: { terminated = true },
      setSettingsRequested: { _ in XCTFail("A failed backup must not schedule Settings") }, waitForTermination: {})
    await controller.restart()
    XCTAssertFalse(created); XCTAssertFalse(terminated)
    XCTAssertFalse(controller.isRestarting); XCTAssertNotNil(controller.errorMessage)
  }

  func testFailedHandshakeCancelsHelperAndDoesNotQuit() async {
    let session = Session(); session.readinessError = AppRelaunchError.notReady
    var terminated = false
    let controller = AppRelaunchController(prepare: {}, makeSession: { session },
      terminate: { terminated = true },
      setSettingsRequested: { _ in XCTFail("A failed handshake must not schedule Settings") }, waitForTermination: {})
    await controller.restart()
    XCTAssertEqual(session.events, ["ready", "cancel"])
    XCTAssertFalse(terminated); XCTAssertNotNil(controller.errorMessage)
  }

  func testHelperIsArmedBeforeQuitAndDisarmedIfTerminationIsCancelled() async {
    let session = Session()
    let controller = AppRelaunchController(prepare: { session.events.append("prepare") }, makeSession: { session },
      terminate: { session.events.append("terminate") },
      setSettingsRequested: { session.events.append($0 ? "scheduleSettings" : "cancelSettings") }, waitForTermination: {})
    await controller.restart()
    XCTAssertEqual(session.events, ["prepare", "ready", "arm", "scheduleSettings", "terminate", "cancel", "cancelSettings"])
    XCTAssertFalse(controller.isRestarting); XCTAssertNotNil(controller.errorMessage)
  }

  func testRepeatedClicksDoNotCreateMultipleRelaunchers() async {
    let session = Session(); session.suspendReadiness = true
    var created = 0
    let controller = AppRelaunchController(prepare: {}, makeSession: { created += 1; return session },
      terminate: {}, setSettingsRequested: { _ in }, waitForTermination: {})
    let first = Task { await controller.restart() }
    for _ in 0..<100 where session.continuation == nil { await Task.yield() }
    XCTAssertNotNil(session.continuation)
    await controller.restart()
    XCTAssertEqual(created, 1)
    session.continuation?.resume()
    await first.value
  }

  func testBundledHelperHandshakeSupportsSpacesAndQuotesWithoutLaunchingApp() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("书架 'quoted' name.app")
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let plist = ["CFBundleIdentifier": "test.bookshelf.relaunch", "CFBundleName": "Relaunch Test", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let script = try XCTUnwrap(L10n.resourceBundle.url(forResource: "relaunch", withExtension: "sh"))
    try FileManager.default.copyItem(at: script, to: resources.appendingPathComponent("relaunch.sh"))
    let bundle = try XCTUnwrap(Bundle(url: app))
    let helper = try AppRelaunchProcess(bundle: bundle)
    defer { helper.cancel() }
    try await helper.waitUntilReady()
    // Never arm the test helper: it cannot open the temporary bundle.
  }

  func testHelperWaitsForParentExitAndRequestsFreshInstanceOfExactApp() async throws {
    try await exerciseHelperHandoff(cancel: false)
  }

  func testCancellingArmedHelperDoesNotLaunchAfterParentExits() async throws {
    try await exerciseHelperHandoff(cancel: true)
  }

  private func exerciseHelperHandoff(cancel: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("书架 'quoted' name.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try Data().write(to: app.appendingPathComponent("Contents/Info.plist"))

    // Replace only the final OS launch command with a recorder. The production
    // handshake, arm, pipe-close, and PID-exit gates run in real child processes;
    // no application is launched and the user's library is never opened.
    let launcher = root.appendingPathComponent("record-launch")
    try """
    #!/bin/sh
    if kill -0 "$BOOKSHELF_TEST_PARENT_PID" 2>/dev/null; then
      printf 'parent still running\\n' > "$BOOKSHELF_TEST_EARLY"
    fi
    printf '%s\\n' "$@" > "$BOOKSHELF_TEST_LAUNCH"
    """.write(to: launcher, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    let source = try XCTUnwrap(L10n.resourceBundle.url(forResource: "relaunch", withExtension: "sh"))
    let contents = try String(contentsOf: source, encoding: .utf8)
    XCTAssertEqual(contents.components(separatedBy: "/usr/bin/open").count, 2)
    let script = root.appendingPathComponent("relaunch.sh")
    try contents.replacingOccurrences(of: "/usr/bin/open", with: "\"\(launcher.path)\"")
      .write(to: script, atomically: true, encoding: .utf8)
    let report = root.appendingPathComponent("launch.txt")
    let premature = root.appendingPathComponent("premature.txt")
    let parent = Process()
    parent.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    parent.arguments = ["-c", """
    import os, select, subprocess, sys, time
    script, app, report, early, cancel = sys.argv[1:]
    env = dict(os.environ, BOOKSHELF_TEST_PARENT_PID=str(os.getpid()),
               BOOKSHELF_TEST_LAUNCH=report, BOOKSHELF_TEST_EARLY=early)
    child = subprocess.Popen(['/bin/sh', script, str(os.getpid()), app],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
    try:
        assert select.select([child.stdout], [], [], 3)[0], 'helper did not become ready'
        assert child.stdout.readline() == b'READY\\n'
        child.stdin.write(b'RELAUNCH\\n')
        child.stdin.flush()
        time.sleep(0.2)
        assert not os.path.exists(report), 'helper launched before parent exit'
        if cancel == 'yes':
            child.terminate()
            child.wait(timeout=3)
    except BaseException:
        child.kill()
        child.wait()
        raise
    # Mimic normal application exit: the OS closes the parent's pipe writer.
    os._exit(0)
    """, script.path, app.path, report.path, premature.path, cancel ? "yes" : "no"]
    try parent.run()
    parent.waitUntilExit()
    XCTAssertEqual(parent.terminationStatus, 0)
    if cancel {
      XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
    } else {
      for _ in 0..<150 {
        if FileManager.default.fileExists(atPath: report.path) { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let arguments = try String(contentsOf: report, encoding: .utf8)
      // -n prevents Launch Services from reusing its stale, exiting app record.
      XCTAssertEqual(arguments, "-n\n-a\n\(app.path)\n")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: premature.path))
  }
}
