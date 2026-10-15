#if DEBUG
import OmiWatchKit
import SwiftUI

/// Simulator screenshots only (`OmiWatchDebugComplicationGallery`): the complication's circular
/// view at real accessoryCircular sizes in each state, plus the live one read back from the shared
/// keychain store the extension reads. Not the installed watch face.
struct ComplicationGallery: View {
    let examples: [(String, ComplicationDisplay)] = [
        ("Recording · 3", ComplicationDisplay(main: .recording, sync: .waiting(3))),
        ("Paused", ComplicationDisplay(main: .paused, sync: .onIPhone)),
        ("Idle · 2", ComplicationDisplay(main: .idle, sync: .waiting(2))),
        ("Unknown", ComplicationDisplay(main: .unknown, sync: .unknown)),
        ("Error", ComplicationDisplay(main: .error, sync: .onIPhone)),
        ("No iPhone", ComplicationDisplay(main: .idle, sync: .notConnected)),
    ]
    let size = CGFloat(UserDefaults.standard.double(forKey: "OmiWatchDebugComplicationSize").nonZero ?? 47)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in content }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 6) {
                let live = ComplicationStore(accessGroup: ComplicationKind.accessGroup).load()
                tile("LIVE (keychain): \(live.map { "\($0.recorder.rawValue) \($0.waitingParts)" } ?? "none")",
                     ComplicationDisplay.evaluate(live, now: Date()))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(examples, id: \.0) { tile($0.0, $0.1) }
                }
            }
        }
    }

    private func tile(_ label: String, _ d: ComplicationDisplay) -> some View {
        VStack(spacing: 2) {
            ComplicationCircle(display: d).frame(width: size, height: size).clipShape(Circle())
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
#endif
