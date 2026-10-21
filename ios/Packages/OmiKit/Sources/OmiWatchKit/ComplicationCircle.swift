#if canImport(WidgetKit) && (os(watchOS) || os(iOS))
import SwiftUI
import WidgetKit

/// The circular watch-face complication. Two compositions were drawn and compared at the real size
/// (about 50 pt on a 46 mm face); `ComplicationCircle` is the chosen one (B).
///
/// - B (chosen): a small waveform mark whose *shape* says the recorder's state (tall bars when
///   recording, the same mark low and grey when idle, two bars when paused, a triangle on an
///   error, a question mark when unknown), and under it the audio still waiting for the iPhone as a short duration
///   ("12m", "<1m", "3h"), a check when the iPhone has it all, or a crossed-out iPhone before
///   pairing. State reads first; the duration is a quiet second line.
/// - A: the duration as the large centre, with a small state mark above it.
///
/// No progress ring or percentage (there is no total to fill toward), no animation. "On the iPhone"
/// is never a claim about the server.
public struct ComplicationCircle: View {
    public let display: ComplicationDisplay
    public init(display: ComplicationDisplay) { self.display = display }

    public var body: some View {
        ComplicationCircleB(display: display)
    }
}

/// B: mark-led.
public struct ComplicationCircleB: View {
    public let display: ComplicationDisplay
    public init(display: ComplicationDisplay) { self.display = display }

    public var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 3) {
                StateMark(main: display.main, scale: 1)
                    .frame(height: 17)
                SyncLabel(sync: display.sync, size: 11)
            }
            .offset(y: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilityLabel)
    }
}

/// A: duration-led.
public struct ComplicationCircleA: View {
    public let display: ComplicationDisplay
    public init(display: ComplicationDisplay) { self.display = display }

    public var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                StateMark(main: display.main, scale: 0.55).frame(height: 10)
                SyncLabel(sync: display.sync, size: 17)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilityLabel)
    }
}

/// The same state mark, for the Watch app's own screen.
public struct RecorderMark: View {
    let main: ComplicationDisplay.Main
    let scale: CGFloat
    public init(main: ComplicationDisplay.Main, scale: CGFloat = 1) {
        self.main = main
        self.scale = scale
    }
    public var body: some View { StateMark(main: main, scale: scale) }
}

/// The recorder's state as a shape (readable without colour on tinted faces).
struct StateMark: View {
    let main: ComplicationDisplay.Main
    let scale: CGFloat

    var body: some View {
        switch main {
        case .recording:
            bars([0.35, 0.7, 1, 0.6, 0.4], color: Color(red: 1, green: 0.27, blue: 0.23)).widgetAccentable()
        case .idle:
            bars([0.2, 0.35, 0.45, 0.3, 0.2], color: .secondary)  // the mark at rest
        case .paused:
            HStack(spacing: 3.5 * scale) {
                Capsule().frame(width: 4.5 * scale, height: 15 * scale)
                Capsule().frame(width: 4.5 * scale, height: 15 * scale)
            }
            .foregroundStyle(Color.orange).widgetAccentable()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15 * scale, weight: .semibold))
                .foregroundStyle(Color.yellow).widgetAccentable()
        case .unknown:
            Image(systemName: "questionmark").font(.system(size: 14 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func bars(_ heights: [CGFloat], color: Color) -> some View {
        HStack(alignment: .center, spacing: 2.2 * scale) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Capsule().frame(width: 3 * scale, height: max(3 * scale, 17 * scale * h))
            }
        }
        .foregroundStyle(color)
    }
}

/// The audio waiting for the iPhone, as a duration with its unit.
struct SyncLabel: View {
    let sync: ComplicationDisplay.Sync
    let size: CGFloat

    var body: some View {
        Group {
            switch sync {
            case .waiting(let seconds?): Text(WaitingAudio.short(seconds)).monospacedDigit()
            case .waiting(nil): Image(systemName: "arrow.up").font(.system(size: size * 0.8, weight: .bold))
            case .onIPhone: Image(systemName: "checkmark").font(.system(size: size * 0.75, weight: .bold))
            case .notConnected: Image(systemName: "iphone.slash").font(.system(size: size * 0.8, weight: .semibold))
            case .unknown: Text(" ")
            }
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .foregroundStyle(.primary)
    }
}
#endif
