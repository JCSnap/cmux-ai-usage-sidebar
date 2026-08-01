import CmuxExtensionKit
import SwiftUI

/// The workspace switcher, grouped by project root.
struct WorkspaceList: View {
    let store: WorkspaceStore

    var body: some View {
        if store.workspaces.isEmpty {
            Text("No workspaces")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.groups) { group in
                        VStack(alignment: .leading, spacing: 1) {
                            if let title = group.title {
                                Text(title)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 2)
                            }
                            ForEach(group.workspaces) { workspace in
                                WorkspaceRow(
                                    workspace: workspace,
                                    isSelected: workspace.id == store.selectedID,
                                    canSelect: store.canSelect
                                ) {
                                    store.select(workspace.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: CmuxSidebarWorkspace
    let isSelected: Bool
    let canSelect: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.title.isEmpty ? "Untitled" : workspace.title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                if workspace.unreadCount > 0 {
                    Text("\(workspace.unreadCount)")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelect)
        .onHover { isHovering = $0 }
        .help(workspace.rootPath?.abbreviatedHomePath ?? workspace.title)
    }

    /// Branch is the more useful line when it differs from the title; the path
    /// is the fallback, since a workspace can exist without a git checkout.
    private var subtitle: String? {
        if let branch = workspace.gitBranch, !branch.isEmpty { return branch }
        return workspace.rootPath?.abbreviatedHomePath
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        return isHovering ? Color.primary.opacity(0.07) : .clear
    }
}
