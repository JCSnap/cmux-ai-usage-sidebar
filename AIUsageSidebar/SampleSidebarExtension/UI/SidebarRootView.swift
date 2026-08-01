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
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // The workspace list takes only the height its rows need, so
                // usage gets the remainder. The cap stops a long workspace list
                // from pushing usage off screen; past it, the list scrolls.
                WorkspaceList(store: workspaces)
                    .frame(height: min(workspaces.estimatedListHeight, geometry.size.height * 0.5))
                Divider()
                UsagePanel()
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
