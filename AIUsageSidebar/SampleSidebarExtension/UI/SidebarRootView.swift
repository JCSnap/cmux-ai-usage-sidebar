import SwiftUI

/// The whole sidebar: cmux workspaces on top, agent usage below.
///
/// An extension sidebar replaces the built-in one instead of sitting beside it,
/// so this view has to provide the workspace switcher as well. Workspaces come
/// first because they are the primary navigation; usage is reference data and
/// collapses out of the way.
struct SidebarRootView: View {
    let workspaces: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceList(store: workspaces)
                .frame(maxHeight: .infinity)
            Divider()
            UsagePanel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
