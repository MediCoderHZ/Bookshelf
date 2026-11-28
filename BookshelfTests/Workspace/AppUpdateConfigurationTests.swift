import Foundation
import XCTest
@testable import Bookshelf

final class AppUpdateConfigurationTests: XCTestCase {
  private var valid: [String: Any] {
    ["BookshelfUpdatesEnabled": "YES",
     "SUFeedURL": "https://raw.githubusercontent.com/MediCoderHZ/Bookshelf/main/Distribution/Updates/appcast.xml",
     "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString()]
  }

  func testPublishedConfigurationAcceptsHTTPSAndEd25519Key() throws {
    let config = try AppUpdateConfiguration(info: valid)
    XCTAssertEqual(config.feedURL.absoluteString, valid["SUFeedURL"] as? String)
    XCTAssertEqual(Data(base64Encoded: config.publicKey)?.count, 32)
  }

  func testUnpublishedAndSwiftPMBuildsNeverEnableUpdates() {
    for flag in [nil, "NO", "$(BOOKSHELF_UPDATES_ENABLED)"] {
      var info = valid
      info["BookshelfUpdatesEnabled"] = flag
      XCTAssertThrowsError(try AppUpdateConfiguration(info: info)) {
        XCTAssertEqual($0 as? AppUpdateConfiguration.ConfigurationError, .disabled)
      }
    }
    XCTAssertThrowsError(try AppUpdateConfiguration(info: [:]))
  }

  func testFeedRejectsPlaintextCredentialsAndUnexpandedSettings() {
    for feed in ["", "http://updates.example.org/appcast.xml", "file:///tmp/appcast.xml",
      "$(BOOKSHELF_UPDATE_FEED_URL)", "https://REPLACE_OWNER.github.io/appcast.xml",
      "https://user:password@updates.example.org/appcast.xml", "https://example.com/appcast.xml",
      "https://updates.example.org/appcast.xml#fragment"] {
      var info = valid
      info["SUFeedURL"] = feed
      XCTAssertThrowsError(try AppUpdateConfiguration(info: info), feed) {
        XCTAssertEqual($0 as? AppUpdateConfiguration.ConfigurationError, .invalidFeed)
      }
    }
  }

  func testPublicKeyRejectsMissingMalformedAndWrongLengthKeys() {
    for key in ["", "REPLACE_PUBLIC_KEY", "$(BOOKSHELF_UPDATE_PUBLIC_KEY)", "not base64",
      Data(repeating: 0, count: 31).base64EncodedString(),
      Data(repeating: 0, count: 33).base64EncodedString()] {
      var info = valid
      info["SUPublicEDKey"] = key
      XCTAssertThrowsError(try AppUpdateConfiguration(info: info), key) {
        XCTAssertEqual($0 as? AppUpdateConfiguration.ConfigurationError, .invalidPublicKey)
      }
    }
  }

  @MainActor
  func testNonApplicationBundleDoesNotStartSparkleOrChangePreferences() {
    let updater = AppUpdater(bundle: Bundle(for: Self.self))
    XCTAssertFalse(updater.isAvailable)
    XCTAssertTrue(updater.canCheckForUpdates) // Manual check explains why updates are unavailable.
    updater.setAutomaticallyChecksForUpdates(true)
    updater.setAutomaticallyDownloadsUpdates(true)
    XCTAssertFalse(updater.automaticallyChecksForUpdates)
    XCTAssertFalse(updater.automaticallyDownloadsUpdates)
  }
}
