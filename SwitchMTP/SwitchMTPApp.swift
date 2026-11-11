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
        WindowGroup("SwitchMTP — Nintendo Switch MTP Explorer") {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 780)
    }
}
