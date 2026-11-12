//
//  SwitchMTPApp.swift
//  SwitchMTP
//
//  Created by Podter on 12/11/26.
//

import SwiftUI

@main
struct SwitchMTPApp: App {
    var body: some Scene {
        WindowGroup("SwitchMTP") {
            ContentView()
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified)
    }
}
