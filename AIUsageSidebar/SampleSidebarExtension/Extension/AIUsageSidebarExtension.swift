import CmuxExtensionKit
import SwiftUI

/// ExtensionKit entry point for the cmux sidebar.
///
/// The manifest requests no read or action scopes. This sidebar shows only
/// agent usage limits, so it never needs cmux workspace data and never asks
/// for permission it would not use.
@main
final class AIUsageSidebarExtension: @MainActor CmuxSidebarExtension {
    static let manifest = CmuxExtensionManifest(
        id: "dev.jcsnap.AIUsageSidebar.Extension",
        displayName: "AI Usage",
        readScopes: [],
        actionScopes: []
    )

    required init() {}

    var body: some View {
        UsageSidebarView()
    }

    func update(context: CmuxSidebarContext) {
        // No cmux state is used, so there is nothing to store per update.
    }
}
