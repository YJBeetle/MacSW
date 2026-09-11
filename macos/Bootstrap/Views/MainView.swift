import SwiftUI

struct MainView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if state.isInstalled && !state.showDeploymentProgress {
                DashboardView(state: state)
            } else {
                WizardView(state: state)
            }
        }
        .onAppear {
            state.checkLicenseStatus()
        }
    }
}
