import SwiftUI

/// The usage half of the sidebar: a header, then accounts grouped by provider.
///
/// The section is collapsible and height-capped so it never crowds out the
/// workspace list above it.
struct UsagePanel: View {
    @State private var store = UsageStore()
    @State private var isExpanded = true
    @State private var showsDetail = false
    @State private var showsHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                content
            }
        }
        .task { store.start() }
        .onDisappear { store.stop() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("AI usage")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            freshness
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showsDetail.toggle() }
            } label: {
                Image(systemName: showsDetail ? "clock.fill" : "clock")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(showsDetail ? Color.accentColor : .secondary)
            .help(showsDetail ? "Hide reset times" : "Show reset times")
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.small)
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(
                        store.isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: store.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.isRefreshing ? Color.accentColor : .secondary)
            .disabled(store.isRefreshing)
            .help(store.isRefreshing ? "Refreshing..." : "Refresh now")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var freshness: some View {
        if store.isRefreshing {
            ProgressView().controlSize(.mini)
        } else {
            switch store.health {
            case .loading:
                ProgressView().controlSize(.mini)
            case .live:
                // Shows staleness rather than a fixed clock time: the useful
                // question is "is this current", not "when was it taken".
                Text(store.snapshot.generatedAt, format: .relative(presentation: .numeric))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            case let .unreachable(reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                    .help("Daemon unreachable: \(reason)")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.snapshot.accounts.isEmpty && (store.snapshot.hidden ?? []).isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(UsageProvider.allCases, id: \.self) { provider in
                        let accounts = store.snapshot.accounts.filter { $0.provider == provider }
                        if !accounts.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.bottom, 2)
                                ForEach(accounts) { account in
                                    AccountRow(account: account, showsDetail: showsDetail)
                                        .contextMenu {
                                            Button("Hide \(account.displayName)") {
                                                Task { await store.setHidden(account.id, true) }
                                            }
                                        }
                                }
                            }
                        }
                    }
                    hiddenList
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    /// "Hidden · N", collapsed. The only way back for an account hidden from
    /// its context menu, short of editing the config file.
    @ViewBuilder
    private var hiddenList: some View {
        let hidden = store.snapshot.hidden ?? []
        if !hidden.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showsHidden.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text("Hidden · \(hidden.count)")
                            .font(.system(size: 9, weight: .semibold))
                            .textCase(.uppercase)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .rotationEffect(.degrees(showsHidden ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsHidden {
                    ForEach(hidden) { account in
                        HStack(spacing: 5) {
                            Text(account.displayName)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(account.provider.displayName)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                            Button("Show") {
                                Task { await store.setHidden(account.id, false) }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .disabled(store.isRefreshing)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No data yet")
                .font(.system(size: 11, weight: .medium))
            Text("Start the daemon with `aiusaged`, or install it with scripts/install-daemon.sh.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }
}
