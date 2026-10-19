import SwiftUI
import WidgetKit
// The views are also compiled into BusBusTests, which checks they fit every size.
#if !BUSBUS_WIDGET
@testable import BusBus
#endif

/// The board's map in a widget: the same engine and the same drawing (`MapRailsCanvas`,
/// `StopLabelsLayer`, `BusPuckMark`), laid out for the box the widget gives it (`WidgetMapLayout`)
/// and held still — a widget is a picture, redrawn with every minute of the countdown.
struct WidgetMapView: View {
    @Environment(\.theme) private var theme
    var frame: WidgetMapFrame

    var body: some View {
        GeometryReader { proxy in
            let scene = WidgetMapLayout.scene(for: frame, in: proxy.size, captions: .localized)
            ZStack(alignment: .topLeading) {
                // The system tints the accented group; the rails and buses are what the map is read by.
                MapRailsCanvas(scene: scene)
                    .widgetAccentable()
                StopLabelsLayer(scene: scene)
                YourStopCaption(convergence: scene.convergence)
                ForEach(scene.pucks) { puck in
                    // Numbers no longer live put the buses where they were likely to be, not where
                    // anyone saw them: drawn back, as a board draws an old fix.
                    BusPuckMark(puck: puck, faded: frame.vehiclesAreStale)
                        .widgetAccentable()
                        .position(puck.center)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            // In one ink the marks cut their ground out of the rails (`Theme.isMonochrome`); the
            // cut has to stop at the map rather than go through to the widget's own background.
            .compositingGroup()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Route map")
    }
}

extension WidgetMapLayout.Captions {
    /// The map's own words in the language it is drawn in, as `StopLabelsLayer` and
    /// `YourStopCaption` set them.
    static var localized: Self {
        Self(yourStop: String(appLocalized: "YOUR STOP"),
             dash: { String(appLocalized: "+\($0) STOPS") })
    }
}
