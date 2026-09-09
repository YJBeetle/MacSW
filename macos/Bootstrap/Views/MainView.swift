import SwiftUI

struct MainView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        Group {
            if appState.isInstalled {
                DashboardView(state: appState)
            } else {
                WizardView(state: appState)
            }
        }
        .frame(minWidth: 500, minHeight: 380)
    }
}
