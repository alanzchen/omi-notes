import OmiBLE
import OmiProtocol
import SwiftUI

/// The 声纹 hub (the People tab): one card per person, you first; the review queue; recurring
/// unknown voices. Each card says only what the server said: its status line, the sample count, the
/// last calibration and, when the server counted any, held-out results.
struct VoicesHubView: View {
    enum Route: Hashable {
        case person(String)
        case unknownVoices
    }

    @Bindable var model: AppModel
    @State private var reviewing = false
    @State private var showEnrollment = false
    @State private var showSettings = false
    #if DEBUG
    @State private var debugRoute: Route?
    #endif

    private var speakers: SpeakersModel { model.speakers }
    private var cards: [Person] { VoicesHub.cards(speakers.people) }
    private var pending: Int { VoicesHub.pendingReview(speakers.people) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if speakers.serverSupportsVoiceReview { reviewCard }
                if speakers.needsWearer { teachCard }
                ForEach(cards) { p in
                    NavigationLink(value: Route.person(p.id)) { personCard(p) }.buttonStyle(.plain)
                }
                if !speakers.suggestions.isEmpty {
                    NavigationLink(value: Route.unknownVoices) { unknownCard }.buttonStyle(.plain).padding(.top, 4)
                }
                if let error = speakers.error {
                    // tap to try again (what loaded stays: one failing call never empties the cards)
                    Button { Task { await speakers.refresh() } } label: { RetryLine(text: error) }
                        .buttonStyle(.plain).frame(maxWidth: .infinity).padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("声纹")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Label("识别设置", systemImage: "slider.horizontal.3") }
            }
        }
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .person(let id): VoicePersonView(model: model, personId: id)
            case .unknownVoices: UnknownVoicesView(model: model)
            }
        }
        .task { await speakers.refresh() }
        .refreshable { await speakers.refresh() }
        .fullScreenCover(isPresented: $reviewing, onDismiss: { Task { await speakers.refresh() } }) {
            VoiceReviewView(model: model)
        }
        .sheet(isPresented: $showEnrollment) { EnrollmentView(model: model) }
        .sheet(isPresented: $showSettings) { RecognitionSettingsView(model: model) }
        #if DEBUG
        // simulator automation: `-OmiNotesDebugVoices review|unknown|person:<name>` opens that screen
        .navigationDestination(item: $debugRoute) { route in
            switch route {
            case .person(let id): VoicePersonView(model: model, personId: id)
            case .unknownVoices: UnknownVoicesView(model: model)
            }
        }
        .onAppear {
            if let name = UserDefaults.standard.string(forKey: "OmiNotesDebugEnrollment") {
                speakers.debugShowEnrollment(name)
                showEnrollment = true
            }
        }
        .task {
            guard let raw = UserDefaults.standard.string(forKey: "OmiNotesDebugVoices") else { return }
            await speakers.refresh()
            if raw == "review" { reviewing = true }
            if raw == "unknown" { debugRoute = .unknownVoices }
            if raw.hasPrefix("person:"), let p = speakers.people.first(where: { $0.name == raw.dropFirst(7) }) {
                debugRoute = .person(p.id)
            }
        }
        #endif
    }

    /// The one call to action: work through the queue, suspicious samples first.
    private var reviewCard: some View {
        Button { reviewing = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "waveform.badge.magnifyingglass").font(.title)
                    .frame(width: 52, height: 52).background(.white.opacity(0.2), in: .circle)
                Text("待确认").font(.title3.bold())
                Spacer(minLength: 0)
                // the queue's total when the server pages it; otherwise flagged samples, labelled 可疑
                if let badge = VoicesHub.reviewBadge(total: speakers.reviewTotal, flagged: pending, preparing: speakers.reviewPreparing) {
                    Text(badge).font(.title2.bold().monospacedDigit())
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.white.opacity(0.22), in: .capsule)
                }
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(VoicesHub.reviewBadge(total: speakers.reviewTotal, flagged: pending, preparing: speakers.reviewPreparing).map { "待确认 \($0)" } ?? "待确认")
    }

    /// No wearer yet: teaching your voice comes first.
    private var teachCard: some View {
        Button { showEnrollment = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.wave.2.fill").font(.title2).foregroundStyle(Color.accentColor)
                    .frame(width: 50, height: 50).background(Color.accentColor.opacity(0.14), in: .circle)
                Text("录入我的声音").font(.headline)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(model.settings.endpoint == nil)
    }

    private func personCard(_ p: Person) -> some View {
        let health = VoiceHealth(p)
        let calibrated = speakers.serverSupportsVoiceCalibration ? VoicesHub.shortTime(p.calibratedAt) : nil
        let measured = VoicesHub.measuredLine(p, calibrationSupported: speakers.serverSupportsVoiceCalibration)
        let review = speakers.serverSupportsVoiceReview ? p.reviewCount ?? 0 : 0
        return HStack(spacing: 14) {
            Avatar(name: p.name, size: 50)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: health.symbol).font(.body).foregroundStyle(.white, health.color)
                        .background(Circle().fill(Color(.secondarySystemGroupedBackground)).padding(-2))
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(p.name).font(.headline).lineLimit(1)
                    if p.isMe { Text("我").font(.caption).foregroundStyle(.secondary) }
                }
                Text(p.statusLine ?? VoiceHealth.fallbackLine(p)).font(.subheadline)
                    .foregroundStyle(health == .active ? Color.secondary : health.color)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    Label("\(p.samples ?? 0)", systemImage: "waveform")
                    if let calibrated { Label(calibrated, systemImage: "clock") }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .labelStyle(TightLabel())
                if let measured {
                    Text(measured).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if review > 0 {
                Text("\(review)").font(.subheadline.bold().monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.orange, in: .capsule)
                    .accessibilityLabel("\(review) 个待确认")
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        .contentShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private var unknownCard: some View {
        let count = speakers.suggestions.count
        return HStack(spacing: 14) {
            HStack(spacing: -14) {
                ForEach(0..<min(count, 3), id: \.self) { _ in
                    UnknownAvatar(size: 34)
                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("陌生声音").font(.headline)
                Text("\(count) 个声音反复出现").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        .contentShape(.rect(cornerRadius: 18))
    }
}
