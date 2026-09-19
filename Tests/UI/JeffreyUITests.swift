import XCTest

/// Parcours d'interface réels dans le simulateur : onboarding, onglets, réglages, objectif.
final class JeffreyUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["WATCHCOACH_NO_HEALTH"] = "1"
        app.launchEnvironment["WATCHCOACH_FAKE_WATCH"] = "1"
        app.launchEnvironment["WATCHCOACH_NO_SPLASH"] = "1"
    }

    private func screenshot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }

    func testOnboardingThenTabs() {
        app.launchEnvironment["WATCHCOACH_RESET"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Moi, c'est Jeffrey."].waitForExistence(timeout: 5))
        screenshot("01-onboarding")
        app.buttons["Me remettre au sport"].tap()
        app.buttons["On fait connaissance"].tap()
        let name = app.textFields["Ton prénom"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap(); name.typeText("Test")
        app.buttons["Continuer"].tap()
        // Montre (fausse montre : prête), micro, dehors : on passe sans autorisations sur le simulateur.
        XCTAssertTrue(app.staticTexts["Ta montre."].waitForExistence(timeout: 3))
        screenshot("02-onboarding-montre")
        app.buttons["Continuer"].tap()
        XCTAssertTrue(app.staticTexts["Ta voix."].waitForExistence(timeout: 3))
        app.buttons["Passer"].tap()
        XCTAssertTrue(app.staticTexts["Dehors."].waitForExistence(timeout: 3))
        app.buttons["Passer"].tap()
        XCTAssertTrue(app.buttons["Plus tard"].waitForExistence(timeout: 3))
        screenshot("03-onboarding-cle")
        app.buttons["Plus tard"].tap()
        XCTAssertTrue(app.staticTexts["Son intelligence."].waitForExistence(timeout: 3))
        app.buttons["Continuer"].tap()
        XCTAssertTrue(app.staticTexts["Presque prêt."].waitForExistence(timeout: 3))
        screenshot("04-onboarding-recap")
        app.buttons["Commencer"].tap()
        XCTAssertTrue(app.staticTexts["On bouge ?"].waitForExistence(timeout: 5))
        screenshot("05-aujourdhui")

        // Onglets
        app.tabBars.buttons["Séances"].tap()
        XCTAssertTrue(app.staticTexts["Tes séances"].waitForExistence(timeout: 3))
        screenshot("06-seances")
        app.tabBars.buttons["Toi"].tap()
        XCTAssertTrue(app.staticTexts["Ton objectif personnel"].waitForExistence(timeout: 3))
        app.buttons["Garder le rythme"].tap()
        screenshot("07-toi")
        app.tabBars.buttons["Jeffrey"].tap()
        XCTAssertTrue(app.staticTexts["Il parle…"].waitForExistence(timeout: 3))
        app.buttons["Discret"].tap()
        app.buttons["Micro iPhone"].tap()
        screenshot("08-jeffrey")
        app.buttons["Avancé"].tap()
        XCTAssertTrue(app.staticTexts["OpenAI"].waitForExistence(timeout: 3))
        screenshot("09-avance")
    }

    func testObjectiveSheetOpensWithFakeWatch() {
        app.launchArguments += ["-pref.onboarded", "YES", "-pref.userName", "Test"]
        app.launch()
        let start = app.buttons["Démarrer avec Jeffrey"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "la montre simulée doit rendre le départ possible")
        start.tap()
        XCTAssertTrue(app.staticTexts["On vise quoi\naujourd'hui ?"].waitForExistence(timeout: 3) || app.buttons["C'est parti"].waitForExistence(timeout: 3))
        app.buttons["Distance"].tap()
        screenshot("08-objectif")
        app.buttons["Retour"].tap()
    }

    func testNoWatchBlocksStart() {
        app.launchEnvironment["WATCHCOACH_FAKE_WATCH"] = "0"
        app.launchArguments += ["-pref.onboarded", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Installe Jeffrey sur ta montre pour démarrer"].waitForExistence(timeout: 5)
                      || app.staticTexts["Ouvre Jeffrey sur ta montre pour démarrer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Démarrer avec Jeffrey"].exists)
        screenshot("09-sans-montre")
    }
}

extension JeffreyUITests {
    func testMemoryViewOpensAndCloses() {
        app.launchArguments += ["-pref.onboarded", "YES", "-pref.userName", "Test"]
        app.launch()
        app.tabBars.buttons["Toi"].tap()
        let card = app.staticTexts["Ce que Jeffrey retient de toi"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        app.swipeUp(); app.swipeUp(); app.swipeUp()
        card.tap()
        XCTAssertTrue(app.textFields["Dis-lui quelque chose à retenir…"].waitForExistence(timeout: 3))
        screenshot("10-memoire")
        app.buttons["Retour"].tap()
        XCTAssertTrue(app.staticTexts["Ton objectif personnel"].waitForExistence(timeout: 3) || card.waitForExistence(timeout: 3))
    }

    func testFeelingsViewOpensAndCloses() {
        app.launchArguments += ["-pref.onboarded", "YES", "-pref.userName", "Test"]
        app.launchEnvironment["WATCHCOACH_SEED_SESSIONS"] = "1"
        app.launch()
        app.tabBars.buttons["Toi"].tap()
        let card = app.staticTexts["Tes derniers ressentis"]
        for _ in 0..<5 where !card.exists { app.swipeUp() }
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        card.tap()
        XCTAssertTrue(app.staticTexts["Ce que tu as dit de chaque séance en la terminant. Jeffrey s'en sert pour doser les suivantes."].waitForExistence(timeout: 3))
        screenshot("11-ressentis")
        app.buttons["Retour"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 3))
    }
}
