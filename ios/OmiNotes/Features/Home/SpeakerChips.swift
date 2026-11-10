import OmiProtocol
import SwiftUI

/// A note's speakers as a few chips (named people first, then by talk time) and "+N more" for the
/// rest, instead of one long comma list. Talk time is shown only once the whole transcript is loaded.
struct SpeakerChips: View {
    let roster: SpeakerRoster
    var showTalkTime: Bool
    @State private var expanded = false

    var body: some View {
        ChipFlow(spacing: 6) {
            ForEach(roster.top) { chip($0, prominent: true) }
            if expanded { ForEach(roster.rest) { chip($0, prominent: false) } }
            if !roster.rest.isEmpty {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    Text(expanded ? "Show less" : "+\(roster.rest.count) more")
                        .font(.subheadline)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(Color(.separator)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    private func chip(_ e: SpeakerRoster.Entry, prominent: Bool) -> some View {
        HStack(spacing: 4) {
            Text(e.displayName).foregroundStyle(.primary)
            if showTalkTime, e.seconds > 0 { Text(SpeakerRoster.talkText(e.seconds)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .font(prominent ? .subheadline : .footnote)
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
        .accessibilityElement(children: .combine)
    }
}

/// Lays children out left to right, wrapping to a new line when the row is full.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal.width ?? .infinity, subviews)
        let width = rows.map { row in row.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY, index = 0
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            let height = row.map(\.height).max() ?? 0
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += height + spacing
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]], x: CGFloat = 0
        for sub in subviews {
            var size = sub.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if !rows[rows.count - 1].isEmpty, x + spacing + size.width > width {
                rows.append([])
                x = 0
            }
            x += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append(size)
        }
        return rows
    }
}
