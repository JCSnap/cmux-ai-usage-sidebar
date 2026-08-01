import CmuxExtensionKit
import SwiftUI

/// ExtensionKit entry point for the cmux sidebar.
///
/// An extension sidebar replaces the built-in sidebar rather than adding to it,
/// so this extension must render the workspace switcher itself. That is why it
/// requests workspace read scopes and the select action. It requests nothing
/// beyond what those rows show: no surfaces, notifications, ports, or pull
/// requests.
@main
final class AIUsageSidebarExtension: @MainActor CmuxSidebarExtension {
    static let manifest = CmuxExtensionManifest(
        id: "dev.jcsnap.AIUsageSidebar.Extension",
        displayName: "AI Usage",
        readScopes: [.workspaceList, .workspaceMetadata, .workspacePaths],
        actionScopes: [.selectWorkspace]
    )

    private let workspaces = WorkspaceStore()

    required init() {}

    var body: some View {
        SidebarRootView(workspaces: workspaces)
    }

    func update(context: CmuxSidebarContext) {
        workspaces.apply(context)
    }
}
