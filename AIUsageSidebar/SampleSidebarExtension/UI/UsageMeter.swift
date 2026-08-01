import SwiftUI

/// A single rate-limit window drawn as a labelled bar.
struct UsageMeter: View {
    let window: UsageWindow

    /// When true the row also states when the window resets. The tooltip says
    /// the same thing, so this is the always-visible form of that detail.
    var showsReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // Labels are normalised to at most three characters, but a
                    // new provider word must truncate rather than wrap.
                    .lineLimit(1)
                    .frame(width: 26, alignment: .leading)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                        Capsule()
                            .fill(UsageMeter.tint(for: window.usedFraction))
                            // A non-zero floor keeps a 0% bar visible as a dot
                            // rather than vanishing, so the row still reads as live.
                            .frame(width: max(3, geometry.size.width * clampedFraction))
                    }
                }
                .frame(height: 5)

                Text("\(window.usedPercent)%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(window.usedFraction >= 0.8 ? .primary : .secondary)
                    .frame(width: 30, alignment: .trailing)
                    .monospacedDigit()
            }

            if showsReset, let reset = resetText {
                Text(reset)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 32)
            }
        }
        .help(helpText)
    }

    private var clampedFraction: Double { max(0, min(1, window.usedFraction)) }

    private var helpText: String {
        guard let reset = resetText else { return "\(window.usedPercent)% used" }
        return "\(window.usedPercent)% used · \(reset)"
    }

    private var resetText: String? {
        guard let resetsAt = window.resetsAt else { return nil }
        return "resets \(Self.compactInterval(until: resetsAt))"
    }

    /// Formats a countdown as "in 4h 20m".
    ///
    /// The system relative style rounds to one unit, which turns a window that
    /// frees up in 90 minutes into "in 2 hours". Two units keep the number
    /// precise enough to plan around.
    static func compactInterval(until date: Date, from now: Date = .now) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d" }
        if hours > 0 { return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h" }
        return "in \(max(1, minutes))m"
    }

    /// Green until half, amber approaching the wall, red once it is close.
    static func tint(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.5: .green
        case ..<0.8: .orange
        default: .red
        }
    }
}
