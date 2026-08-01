import CmuxExtensionKit
import Foundation
import Observation

/// Holds the cmux workspace snapshot and forwards selections back to cmux.
///
/// cmux pushes a new snapshot on every workspace change. The extension keeps
/// the latest one and the host channel that came with it, because the channel
/// is only valid for the connection that delivered it.
@Observable
@MainActor
final class WorkspaceStore {
    private(set) var workspaces: [CmuxSidebarWorkspace] = []
    private(set) var selectedID: UUID?

    /// False until cmux confirms the select action scope. cmux rejects an
    /// ungranted action, so the rows stay inert rather than fail on click.
    private(set) var canSelect = false

    @ObservationIgnored private var host: CmuxSidebarHost?

    func apply(_ context: CmuxSidebarContext) {
        workspaces = context.snapshot.workspaces
        selectedID = context.snapshot.selectedWorkspaceID
        canSelect = context.grantedActionScopes.contains(.selectWorkspace)
        host = context.host
    }

    func select(_ id: UUID) {
        guard canSelect, let host else { return }
        Task { try? await host.selectWorkspace(id) }
    }

    /// Workspaces grouped by project root, in first-seen order.
    ///
    /// cmux sends a flat list. Grouping restores the project headings that the
    /// built-in sidebar shows.
    var groups: [WorkspaceGroup] {
        var order: [String] = []
        var buckets: [String: [CmuxSidebarWorkspace]] = [:]
        for workspace in workspaces {
            let key = workspace.projectRootPath ?? ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(workspace)
        }
        return order.map { WorkspaceGroup(path: $0, workspaces: buckets[$0] ?? []) }
    }
}

struct WorkspaceGroup: Identifiable {
    var path: String
    var workspaces: [CmuxSidebarWorkspace]

    var id: String { path }

    /// Empty when the extension has no path scope, or cmux sent no root.
    var title: String? {
        path.isEmpty ? nil : path.abbreviatedHomePath
    }
}

extension String {
    /// Replaces the home directory prefix with `~`, as cmux does.
    var abbreviatedHomePath: String {
        let home = NSHomeDirectory()
        guard hasPrefix(home) else { return self }
        return "~" + dropFirst(home.count)
    }
}
