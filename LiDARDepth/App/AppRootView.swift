/*
 Abstract:
 App entry wrapper — splash then main tabs.
 */

import SwiftUI

struct AppRootView: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            MainTabView()
                .opacity(showSplash ? 0 : 1)

            if showSplash {
                ScanProSplashView {
                    showSplash = false
                }
                .transition(.opacity)
            }
        }
    }
}
