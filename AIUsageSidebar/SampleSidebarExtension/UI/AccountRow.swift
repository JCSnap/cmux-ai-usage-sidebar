import SwiftUI

/// One account: a header line, then one meter per rate-limit window.
struct AccountRow: View {
    let account: UsageAccount

    /// Reveals reset times and the signed-in address. Driven by one toggle in
    /// the panel header, so every account discloses together.
    var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if showsDetail, let email = account.email {
                Text(email)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            switch account.state {
            case .ok:
                ForEach(groupedWindows, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        if let name = group.name {
                            Text(name)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                                .lineLimit(1)
                        }
                        ForEach(group.windows) { UsageMeter(window: $0, showsReset: showsDetail) }
                    }
                }
            case .signedOut:
                Text("Not signed in")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            case .error:
                Text(account.detail ?? "Unavailable")
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(account.displayName)
                .font(.system(size: 11, weight: .semibold))
            if let plan = account.plan {
                Text(plan)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .help(account.email ?? account.displayName)
    }

    private var statusColor: Color {
        switch account.state {
        case .signedOut: .secondary.opacity(0.4)
        case .error: .red
        case .ok: UsageMeter.tint(for: account.worstWindow?.usedFraction ?? 0)
        }
    }

    /// Antigravity meters two model groups; the other providers report one
    /// unnamed set. Grouping here keeps the row shape identical for both.
    private var groupedWindows: [(name: String?, windows: [UsageWindow])] {
        var order: [String?] = []
        var byGroup: [String?: [UsageWindow]] = [:]
        for window in account.windows {
            if byGroup[window.group] == nil { order.append(window.group) }
            byGroup[window.group, default: []].append(window)
        }
        return order.map { (name: $0, windows: byGroup[$0] ?? []) }
    }
}
