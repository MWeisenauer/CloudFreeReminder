//
//  CloudFreeReminderApp.swift
//  CloudFreeReminder
//
//  Created by Markus on 6/19/26.
//

import SwiftUI
import CoreData

@main
struct CloudFreeReminderApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
