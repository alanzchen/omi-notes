import OmiBLE
import OmiProtocol
import SwiftUI

// Small pieces shared by the 声纹 screens.

/// How a person's voice model is doing, as one symbol on their avatar (the words are the server's
/// status line next to it).
enum VoiceHealth {
    case active, attention, off

    init(_ p: Person) {
        if p.autoActive == true { self = .active } else if (p.reviewCount ?? 0) > 0 { self = .attention } else { self = .off }
    }

    var color: Color {
        switch self {
        case .active: return .green
        case .attention: return .orange
        case .off: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .active: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .off: return "pause.circle.fill"
        }
    }

    /// An older server sends no status line: say only what its fields support.
    static func fallbackLine(_ p: Person) -> String {
        if p.autoActive == true { return "已启用" }
        return p.voiceReady == true ? "仅建议" : "需要更多样本"
    }
}

/// A grey "?" in the avatar's place for a voice nobody has named.
struct UnknownAvatar: View {
    var size: CGFloat = 44

    var body: some View {
        Text("?")
            .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(red: 0.5, green: 0.5, blue: 0.54), Color(red: 0.33, green: 0.33, blue: 0.36)],
                                       startPoint: .top, endPoint: .bottom), in: .circle)
            .accessibilityHidden(true)
    }
}

/// A small colored capsule (a flag reason, "我").
struct VoicePill: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.semibold)).lineLimit(1).fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.16), in: .capsule)
    }
}

/// The reasons the server gave, as pills: doubts in orange, naming in the accent color.
struct ReasonPills: View {
    let reasons: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Set(reasons.map(VoicesHub.reasonLabel))).sorted(), id: \.self) { label in
                let naming = label == VoicesHub.reasonLabel("auto") || label == VoicesHub.reasonLabel("possible")
                VoicePill(text: label, color: naming ? .accentColor : .orange,
                          symbol: naming ? nil : "exclamationmark.triangle.fill")
            }
        }
    }
}

/// Icon and number close together.
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}

/// A short dark toast with one action.
struct VoiceToast: View {
    let symbol: String
    let tint: Color
    let text: String
    var action: String?
    var perform: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 0)
            if let action { Button(action, action: perform).fontWeight(.semibold) }
        }
        .font(.subheadline)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(white: 0.17).opacity(0.96), in: .rect(cornerRadius: 16))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// A voice change needed this person's consent (`409 consent_required`): first the one-time
/// acknowledgment, then the owner's attestation that the person knows. Then the owner tries again.
struct PersonConsentFlow: ViewModifier {
    @Bindable var model: AppModel
    let personId: String?
    let done: () -> Void
    /// The attestation the server didn't take, and why: shown until read (not lost with the alert).
    @State private var failed: String?

    private var person: Person? { personId.flatMap { id in model.speakers.people.first { $0.id == id } } }
    private var acknowledged: Bool { model.speakers.settings?.acknowledged == true }

    func body(content: Content) -> some View {
        content
            .alert("\(person?.name ?? "TA") 知道吗？", isPresented: .init(get: { person != nil && acknowledged }, set: { if !$0 { done() } }),
                   presenting: person) { p in
                Button("取消", role: .cancel) {}
                Button("TA 知道") {
                    Task {
                        if await !model.speakers.attest(p) {
                            failed = model.speakers.error ?? "请稍后再试"
                        }
                    }
                }
            } message: { p in
                Text("确认 \(p.name) 知道 Omi Notes 会识别 TA 的声音，然后再试一次。")
            }
            .alert("没能保存", isPresented: .init(get: { failed != nil }, set: { if !$0 { failed = nil } }), presenting: failed) { _ in
                Button("好") {}
            } message: { why in
                Text(why)
            }
            .sheet(isPresented: .init(get: { person != nil && !acknowledged }, set: { if !$0 { done() } })) {
                RecognitionConsentView(model: model)
            }
    }
}

extension View {
    func personConsent(_ model: AppModel, personId: String?, done: @escaping () -> Void) -> some View {
        modifier(PersonConsentFlow(model: model, personId: personId, done: done))
    }
}

enum VoiceClock {
    static func text(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
