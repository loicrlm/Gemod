//
//  Gemod_for_MacApp.swift
//  Gemod for Mac
//
//  Created by Loic on 2026/5/12.
//

import AppKit
import SwiftUI

@main
struct Gemod_for_MacApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    applyMainWindowTitle()
                }
        }
    }

    private static var titleWithVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let version, !version.isEmpty {
            return "Gemod \(version)"
        }
        return "Gemod"
    }

    private func applyMainWindowTitle() {
        let title = Self.titleWithVersion
        let apply = {
            if let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) {
                window.title = title
            }
        }
        DispatchQueue.main.async(execute: apply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: apply)
    }
}
