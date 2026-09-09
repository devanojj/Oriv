//
//  OrivApp.swift
//  Oriv
//
//  Created by Devano Jose on 26/07/2026.
//

import SwiftUI

@main
struct OrivApp: App {

    /// Unit tests are hosted *inside* this app. Booting the real UI would start keychain
    /// reads, HealthKit queries and permission prompts in parallel with the tests, which
    /// has previously both crashed the test process and hung whole runs on the system
    /// permission sheet. Tests construct the objects they need themselves, so the host
    /// should stay inert.
    ///
    /// UI tests are unaffected: XCTest is injected into the app process only for unit
    /// testing, so `RootView` still launches normally there.
    private var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    var body: some Scene {
        WindowGroup {
            if isRunningUnitTests {
                Color.clear
            } else {
                RootView()
            }
        }
    }
}
