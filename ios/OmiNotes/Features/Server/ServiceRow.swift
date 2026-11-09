import OmiProtocol
import SwiftUI

/// One configured service on one line: a health dot and its short name (full names in the details).
struct ServiceRow: View {
    let title: String
    let label: ServiceLabel

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true) }
                Text(label.text).lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityValue([label.text, healthWords].compactMap { $0 }.joined(separator: ", "))
    }

    private var color: Color? {
        switch label.health {
        case .ok: return .green
        case .down: return .red
        case .notSetUp: return .orange
        case .unknown: return nil
        }
    }

    private var healthWords: String? {
        switch label.health {
        case .ok: return "configured"
        case .down, .notSetUp, .unknown: return nil  // already in the text, or nothing known
        }
    }
}

/// A service's full model names and settings, title above value (long names wrap left-aligned).
struct ServiceDetails: View {
    let title: String
    let details: [ServiceLabel.Detail]

    var body: some View {
        if !details.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.footnote.weight(.semibold))
                ForEach(details, id: \.self) { d in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.title).font(.caption).foregroundStyle(.secondary)
                        Text(d.value).font(.footnote).textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
