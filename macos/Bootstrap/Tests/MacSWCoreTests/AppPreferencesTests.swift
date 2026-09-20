import Foundation
import XCTest
@testable import MacSWCore

final class AppPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "MacSW-Preferences-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(suite)
    }

    override func tearDownWithError() throws {
        suite.removePersistentDomain(forName: suiteName)
    }

    func testAutoLaunchDefaultsToOffSoOpeningTheAppStaysLightweight() {
        XCTAssertFalse(AppPreferences.autoLaunchSolidWorksDefault)
        XCTAssertFalse(AppPreferences.autoLaunchSolidWorks(defaults: suite))
    }

    func testExplicitChoiceIsHonouredIncludingFalse() {
        let key = AppPreferences.autoLaunchSolidWorksKey
        suite.set(true, forKey: key)
        XCTAssertTrue(AppPreferences.autoLaunchSolidWorks(defaults: suite))
        suite.set(false, forKey: key)
        XCTAssertFalse(AppPreferences.autoLaunchSolidWorks(defaults: suite))
    }
}
