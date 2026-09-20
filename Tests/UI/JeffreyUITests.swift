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
        XCTAssertTrue(app.staticTexts["Ton rythme. Ton coach."].waitForExistence(timeout: 5))
        screenshot("01-onboarding")
        app.buttons["Me remettre au sport"].tap()
        app.buttons["Faire connaissance"].tap()
        let name = app.textFields["Prénom"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap(); name.typeText("Test")
        app.buttons["Continuer"].tap()
        // Montre (fausse montre : prête), micro, dehors : on passe sans autorisations sur le simulateur.
        XCTAssertTrue(app.staticTexts["Ton cœur donne le tempo."].waitForExistence(timeout: 3))
        screenshot("02-onboarding-montre")
        app.buttons["Continuer"].tap()
        XCTAssertTrue(app.staticTexts["Parle.\nJeffrey t'écoute."].waitForExistence(timeout: 3))
        // Plus de « Passer » ici : on autorise le micro (alerte système acceptée) avant de continuer.
        let monitor = addUIInterruptionMonitor(withDescription: "Micro") { alert in
            for label in ["Allow", "Autoriser", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        if app.buttons["Autoriser"].waitForExistence(timeout: 2) { app.buttons["Autoriser"].tap(); app.tap() }
        let continuer = app.buttons["Continuer"]
        XCTAssertTrue(continuer.waitForExistence(timeout: 5))
        continuer.tap()
        removeUIInterruptionMonitor(monitor)
        XCTAssertTrue(app.staticTexts["Chaque sortie compte."].waitForExistence(timeout: 5))
        // Position et mouvement : autorisations acceptées via les alertes système.
        let monitor2 = addUIInterruptionMonitor(withDescription: "Autorisations") { alert in
            for label in ["Allow While Using App", "Allow", "Autoriser lorsque l'app est active", "Autoriser", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        for _ in 0..<2 where app.buttons["Autoriser"].waitForExistence(timeout: 2) { app.buttons["Autoriser"].firstMatch.tap(); app.tap(); sleep(1) }
        XCTAssertTrue(app.buttons["Continuer"].waitForExistence(timeout: 5))
        app.buttons["Continuer"].tap()
        removeUIInterruptionMonitor(monitor2)
        // Compte Apple obligatoire : sans connexion (impossible sur simulateur), le parcours s'arrête ici.
        XCTAssertTrue(app.staticTexts["Ton coach, à toi."].waitForExistence(timeout: 3))
        screenshot("03-onboarding-compte")
        XCTAssertFalse(app.buttons["Continuer"].isEnabled)
        XCTAssertFalse(app.buttons["Plus tard"].exists)
        // Suite des onglets : app déjà configurée.
        app.terminate()
        app.launchEnvironment["WATCHCOACH_RESET"] = "0"
        app.launchArguments += ["-pref.onboarded", "YES", "-pref.setupVersion", "2", "-pref.userName", "Test"]
        app.launch()
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
        // « Avancé » est réservé à l'administrateur : absent sans compte.
        XCTAssertFalse(app.buttons["Avancé"].exists)
    }

    func testObjectiveSheetOpensWithFakeWatch() {
        app.launchArguments += ["-pref.onboarded", "YES", "-pref.setupVersion", "2", "-pref.userName", "Test"]
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
        app.launchArguments += ["-pref.onboarded", "YES", "-pref.setupVersion", "2"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Montre déconnectée"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Montre déconnectée : ni l'iPhone ni la montre ne peuvent démarrer."].exists)
        XCTAssertFalse(app.buttons["Démarrer avec Jeffrey"].exists)
        screenshot("09-sans-montre")
    }
}

extension JeffreyUITests {
    func testMemoryViewOpensAndCloses() {
        app.launchArguments += ["-pref.onboarded", "YES", "-pref.setupVersion", "2", "-pref.userName", "Test"]
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
        app.launchArguments += ["-pref.onboarded", "YES", "-pref.setupVersion", "2", "-pref.userName", "Test"]
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
