import SwiftUI

/// A single rate-limit window drawn as a labelled bar.
struct UsageMeter: View {
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 6) {
            Text(window.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

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
        .help(helpText)
    }

    private var clampedFraction: Double { max(0, min(1, window.usedFraction)) }

    private var helpText: String {
        guard let resetsAt = window.resetsAt else { return "\(window.usedPercent)% used" }
        let relative = resetsAt.formatted(.relative(presentation: .named))
        return "\(window.usedPercent)% used · resets \(relative)"
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
