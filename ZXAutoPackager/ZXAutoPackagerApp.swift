//
//  ZXAutoPackagerApp.swift
//  ZXAutoPackager
//
//  Created by ZX on 2026/9/23.
//

import SwiftUI

@main
struct ZXAutoPackagerApp: App {
    @AppStorage("ZXAutoPackager.language") private var language = AppLanguage.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, (AppLanguage(rawValue: language) ?? .system).locale)
        }
    }
}
