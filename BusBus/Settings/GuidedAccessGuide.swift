#if os(iOS)
import SwiftUI

/// The row under the wall mode toggle that leads to the guide. A spare iPhone out of a drawer is
/// the usual wall display, and Guided Access is what stops it wandering off the board.
struct GuidedAccessGuideLink: View {
    var body: some View {
        NavigationLink {
            GuidedAccessGuide()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn a spare iPhone into a bus board")
                    Text("Got a spare iPhone in a drawer? Set up Guided Access to lock it into this app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.rectangle.stack")
            }
        }
    }
}

/// Guided Access is set up in the system's Settings, which an app cannot open to the right page,
/// so this walks the rider there and back.
struct GuidedAccessGuide: View {
    private struct Step: Identifiable {
        let id: Int
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private let steps: [Step] = [
        Step(id: 1,
             title: "Turn on Guided Access",
             detail: "Open the Settings app, go to **Accessibility › Guided Access** and turn it on."),
        Step(id: 2,
             title: "Choose a passcode",
             detail: "Tap **Passcode Settings › Set Guided Access Passcode**. Pick one only you know: it is what lets you out again. You can allow Face ID or Touch ID too."),
        Step(id: 3,
             title: "Keep it on power",
             detail: "Plug the iPhone into a charger where it will stay: a wall display is on all day. A **MagSafe** charger mounted on the wall works well, as the iPhone snaps onto it sideways and charges while it shows the board."),
        Step(id: 4,
             title: "Start it here",
             detail: "Come back here, turn on **Wall mode** and tap **Done**. Then triple-click the side button (or the Home button) and tap **Start**."),
        Step(id: 5,
             title: "To get out",
             detail: "Triple-click the same button, enter your passcode and tap **End**."),
        Step(id: 6,
             title: "Choose when it shows",
             detail: "Under **Screen on** in this app's settings, add the times you usually head out, like weekday mornings. Outside these times the screen goes black. Tap it to show the board for 20 seconds. With no times added, the board shows all the time."),
    ]

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Turn a spare iPhone into a bus board")
                        .font(.title3.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Image("GuidedAccessWall")
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("An iPhone on its side on a MagSafe charger on the wall, showing the board in wall mode")
                    Text("Guided Access is built into iOS. It keeps the iPhone in one app: the Home Screen, Control Center and notifications are out of reach, and leaving takes a passcode.")
                    Text("With it, an old iPhone becomes a bus board nobody can wander off — not a child, not a guest, not a stray swipe. The board keeps the screen on by itself.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section("How to set it up") {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Text(verbatim: step.id.formatted())
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.accentColor, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(.headline)
                            Text(step.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Guided Access")
        .navigationBarTitleDisplayMode(.inline)
        .analyticsScreen("guided_access_guide")
    }
}
#endif
