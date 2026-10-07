import SwiftUI

/// One account: a header line, then one meter per rate-limit window.
///
/// A CLIProxyAPI pool draws the same way, with bars that average its logins.
/// Its header carries a disclosure that lists each login as a nested row.
struct AccountRow: View {
    let account: UsageAccount

    /// Reveals reset times and the signed-in address. Driven by one toggle in
    /// the panel header, so every account discloses together.
    var showsDetail = false

    /// A login inside an expanded pool. Drawn smaller, because the pool row
    /// above it already names the provider and the alias.
    var isMember = false

    /// Per pool, not panel-wide like `showsDetail`: one pool is usually
    /// opened to see which login is hot, and the others can stay closed.
    @State private var showsMembers = false

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
            case .ok, .stale:
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
                if account.state == .stale { staleNote }
                if showsMembers { memberList }
            case .signedOut:
                Text("Not signed in")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            case .error:
                Text(account.detail ?? "Unavailable")
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(2)
                if showsMembers { memberList }
            }
        }
        .padding(.vertical, isMember ? 1 : 3)
    }

    /// The pooled logins, indented under a rule so they read as parts of the
    /// row above rather than as accounts of their own.
    private var memberList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(account.members ?? []) { member in
                AccountRow(account: member, showsDetail: showsDetail, isMember: true)
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: 1)
        }
        .padding(.top, 2)
    }

    /// "avg · 5" with a chevron. Names what the bars are, because an averaged
    /// bar otherwise looks like one login that is barely used.
    private var poolToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showsMembers.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text("avg · \(account.members?.count ?? 0)")
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .rotationEffect(.degrees(showsMembers ? 90 : 0))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showsMembers
              ? "Hide the pooled accounts"
              : "Bars average \(account.members?.count ?? 0) pooled accounts. Show each one.")
    }

    private var header: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: isMember ? 5 : 6, height: isMember ? 5 : 6)
            Text(account.displayName)
                .font(.system(size: isMember ? 10 : 11, weight: isMember ? .medium : .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let plan = account.plan {
                Text(plan)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 0)
            if account.isPool { poolToggle }
        }
        .help(account.email ?? account.displayName)
    }

    private var statusColor: Color {
        switch account.state {
        case .signedOut: .secondary.opacity(0.4)
        case .error: .red
        case .stale: .yellow
        case .ok: UsageMeter.tint(for: account.worstWindow?.usedFraction ?? 0)
        }
    }

    /// Marks bars that the last refresh could not renew. The age matters more
    /// than the cause, so the cause appears only with the rest of the detail.
    private var staleNote: some View {
        Text(showsDetail ? "Stale · \(staleAge) · \(account.detail ?? "refresh failed")"
                         : "Stale · \(staleAge)")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .lineLimit(2)
    }

    /// How old the shown numbers are, in whole minutes. The panel repolls every
    /// 60 seconds, which redraws this often enough.
    private var staleAge: String {
        guard let updatedAt = account.updatedAt else { return "earlier" }
        return "\(max(1, Int(Date().timeIntervalSince(updatedAt) / 60)))m old"
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
