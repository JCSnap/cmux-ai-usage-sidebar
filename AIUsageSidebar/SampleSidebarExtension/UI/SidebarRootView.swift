import SwiftUI

/// The whole sidebar: cmux workspaces on top, agent usage below.
///
/// An extension sidebar replaces the built-in one instead of sitting beside it,
/// so this view has to provide the workspace switcher as well. Workspaces come
/// first because they are the primary navigation; usage is reference data and
/// collapses out of the way.
struct SidebarRootView: View {
    let workspaces: WorkspaceStore

    /// Chosen workspace height in points, or 0 to fit the rows automatically.
    /// Stored so the split survives a sidebar reload.
    @AppStorage("workspaceListHeight") private var chosenHeight: Double = 0

    /// Height when the current drag began. Held so each drag applies to where
    /// the divider started, not to the value the previous frame just wrote.
    @State private var dragBaseline: Double?

    private static let minimumWorkspaceHeight: Double = 40
    private static let minimumUsageHeight: Double = 90

    var body: some View {
        GeometryReader { geometry in
            let available = Double(geometry.size.height)
            VStack(spacing: 0) {
                WorkspaceList(store: workspaces)
                    .frame(height: height(in: available))
                SplitHandle(
                    onDrag: { translation in
                        let baseline = dragBaseline ?? height(in: available)
                        dragBaseline = baseline
                        chosenHeight = clamp(baseline + Double(translation), in: available)
                    },
                    onDragEnded: { dragBaseline = nil },
                    onReset: {
                        dragBaseline = nil
                        chosenHeight = 0
                    }
                )
                UsagePanel()
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The chosen height, or an automatic one that fits the rows.
    ///
    /// Automatic sizing stays the default so the sidebar is useful before any
    /// drag, and a double click returns to it.
    private func height(in available: Double) -> Double {
        guard chosenHeight > 0 else {
            return min(Double(workspaces.estimatedListHeight), available * 0.5)
        }
        return clamp(chosenHeight, in: available)
    }

    /// Keeps both halves usable, and keeps a stored height sane after the
    /// window is resized smaller than it was when the height was chosen.
    private func clamp(_ value: Double, in available: Double) -> Double {
        let ceiling = max(Self.minimumWorkspaceHeight, available - Self.minimumUsageHeight)
        return min(max(value, Self.minimumWorkspaceHeight), ceiling)
    }
}
