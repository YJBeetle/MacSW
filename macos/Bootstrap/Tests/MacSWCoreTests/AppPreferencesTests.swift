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

    /// 没写过这个键就等于没选过：打开 App 不能顺手把 SOLIDWORKS 拉起来。
    func testAutoLaunchDefaultsToOffSoOpeningTheAppStaysLightweight() {
        XCTAssertFalse(AppPreferences.autoLaunchSolidWorks(defaults: suite))
        suite.set(true, forKey: "MacSW.somethingElse")
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
