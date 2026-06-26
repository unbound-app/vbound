//
//  vboundApp.swift
//  vbound
//
//  Created by Adrian Castro on 26/6/26.
//

import SwiftUI

@main
struct vboundApp: App {
    @State private var manager = AppController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(manager)
        }
        .windowResizability(.contentSize)
    }
}
