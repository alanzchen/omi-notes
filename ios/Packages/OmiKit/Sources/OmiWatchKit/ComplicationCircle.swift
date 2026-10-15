#if canImport(WidgetKit) && (os(watchOS) || os(iOS))
import SwiftUI
import WidgetKit

/// The circular watch-face complication: the recorder's state as one glyph whose *shape* differs
/// by state (so it reads on tinted and monochrome faces too), and below it the Watch's own queue:
/// an up arrow with the number of parts waiting for the iPhone, a check when the iPhone has them
/// all, or a crossed iPhone before pairing. No progress ring (there is no total to fill toward).
public struct ComplicationCircle: View {
    public let display: ComplicationDisplay

    public init(display: ComplicationDisplay) {
        self.display = display
    }

    public var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                main
                sync.font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilityLabel)
    }

    @ViewBuilder private var main: some View {
        let size: CGFloat = 19
        switch display.main {
        case .recording:
            Image(systemName: "mic.fill").font(.system(size: size, weight: .semibold))
                .overlay(alignment: .topTrailing) {
                    Circle().fill(.red).frame(width: 6, height: 6).offset(x: 5, y: -1).widgetAccentable()
                }
        case .paused:
            Image(systemName: "pause.fill").font(.system(size: size - 2, weight: .bold)).foregroundStyle(.orange).widgetAccentable()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size - 3, weight: .semibold)).foregroundStyle(.yellow)
                .widgetAccentable()
        case .idle:
            Image(systemName: "mic").font(.system(size: size, weight: .regular)).foregroundStyle(.secondary)
        case .unknown:
            Image(systemName: "questionmark").font(.system(size: size - 3, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var sync: some View {
        switch display.sync {
        case .waiting(let n):
            HStack(spacing: 1) {
                Image(systemName: "arrow.up")
                Text(n > 99 ? "99+" : "\(n)").monospacedDigit()
            }
        case .onIPhone: Image(systemName: "checkmark")
        case .notConnected: Image(systemName: "iphone.slash")
        case .unknown: Text(" ")
        }
    }
}
#endif
