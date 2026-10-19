import SwiftUI

extension View {
    /// Logs this screen to Analytics each time it comes up: a sheet each time it is presented, a
    /// pushed screen each time it is pushed or returned to.
    func analyticsScreen(_ name: String) -> some View {
        onAppear { Telemetry.screen(name) }
    }
}
