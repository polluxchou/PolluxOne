//
//  Pollux_OneApp.swift
//  Pollux One
//

import SwiftUI

@main
struct Pollux_OneApp: App {
    @State private var environment = AppEnvironment(backend: MockBackendClient())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .preferredColorScheme(.dark)
        }
    }
}
