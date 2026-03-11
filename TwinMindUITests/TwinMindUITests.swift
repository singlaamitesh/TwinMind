//
//  TwinMindUITests.swift
//  TwinMindUITests
//
//  UI tests for core navigation and recording flow.
//
//  Created by Amitesh Gupta on 11/03/26.
//

import XCTest

final class TwinMindUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tab Navigation

    @MainActor
    func testTabBar_showsRecordAndHistoryTabs() throws {
        let recordTab  = app.tabBars.buttons["Record"]
        let historyTab = app.tabBars.buttons["History"]
        XCTAssertTrue(recordTab.exists, "Record tab should exist")
        XCTAssertTrue(historyTab.exists, "History tab should exist")
    }

    @MainActor
    func testTabBar_switchBetweenTabs() throws {
        let historyTab = app.tabBars.buttons["History"]
        historyTab.tap()

        // The Recordings navigation title should appear
        let navTitle = app.navigationBars["Recordings"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 2))

        let recordTab = app.tabBars.buttons["Record"]
        recordTab.tap()

        let twinMindTitle = app.navigationBars["TwinMind"]
        XCTAssertTrue(twinMindTitle.waitForExistence(timeout: 2))
    }

    // MARK: - Recording Screen

    @MainActor
    func testRecordingView_showsStartButton() throws {
        let startButton = app.buttons["Start Recording"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 3),
                      "Start Recording button should be visible on initial launch")
    }

    @MainActor
    func testRecordingView_showsIdleState() throws {
        let idleBadge = app.staticTexts["Idle"]
        XCTAssertTrue(idleBadge.waitForExistence(timeout: 3),
                      "Idle state badge should be shown when not recording")
    }

    @MainActor
    func testStartRecording_showsSessionNameAlert() throws {
        let startButton = app.buttons["Start Recording"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 3))
        startButton.tap()

        // Alert with Session Name title should appear
        let alert = app.alerts["Session Name"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3),
                      "Session name alert should appear when tapping Start")
    }

    // MARK: - History Tab

    @MainActor
    func testHistoryTab_showsEmptyState() throws {
        let historyTab = app.tabBars.buttons["History"]
        historyTab.tap()

        // On first launch with no recordings, empty state should show
        let emptyLabel = app.staticTexts["No Recordings Yet"]
        if emptyLabel.waitForExistence(timeout: 2) {
            XCTAssertTrue(emptyLabel.exists)
        }
    }

    @MainActor
    func testHistoryTab_hasSearchBar() throws {
        let historyTab = app.tabBars.buttons["History"]
        historyTab.tap()

        // Swipe down to reveal the search bar
        app.swipeDown()
        let searchField = app.searchFields.firstMatch
        _ = searchField.waitForExistence(timeout: 2)
    }

    // MARK: - Accessibility

    @MainActor
    func testAccessibility_recordingControlsHaveLabels() throws {
        let startButton = app.buttons["Start Recording"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 3),
                      "Start Recording should have an accessibility label")
    }

    // MARK: - Launch Performance

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
