/*
 Abstract:
 Root tabs: original depth sample + LiDAR mesh scan demo.
 */

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            ContentView()
                .tabItem {
                    Label("Depth", systemImage: "camera.metering.matrix")
                }
            LiDARMeshScanContainer()
                .tabItem {
                    Label("Quét 3D", systemImage: "cube.transparent")
                }
        }
    }
}
