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
    ///
    /// Only written when a drag ends. `@AppStorage` is a `UserDefaults` adapter,
    /// not a state variable: each write also posts a change notification that
    /// SwiftUI observes a runloop turn later, so writing it per pointer event
    /// laid the view out twice per event, a frame apart. The late pass could
    /// land after the next event and briefly redraw the divider at the previous
    /// height, which is what made the panel judder during a drag.
    @AppStorage("workspaceListHeight") private var chosenHeight: Double = 0

    /// The drag in progress, if any. Its height supersedes the stored one, so
    /// the divider tracks the pointer without touching `UserDefaults`.
    @State private var drag: Drag?

    private static let minimumWorkspaceHeight: Double = 40
    private static let minimumUsageHeight: Double = 90

    /// A drag needs both the height it started from and the height it is at.
    ///
    /// The baseline is fixed for the whole gesture because `DragGesture` reports
    /// translation cumulatively; applying it to a moving value would compound.
    private struct Drag {
        var baseline: Double
        var height: Double
    }

    var body: some View {
        GeometryReader { geometry in
            let available = Double(geometry.size.height)
            VStack(spacing: 0) {
                WorkspaceList(store: workspaces)
                    .frame(height: height(in: available))
                SplitHandle(
                    onDrag: { translation in
                        let baseline = drag?.baseline ?? height(in: available)
                        drag = Drag(
                            baseline: baseline,
                            height: clamp(baseline + Double(translation), in: available)
                        )
                    },
                    onDragEnded: {
                        if let drag { chosenHeight = drag.height }
                        drag = nil
                    },
                    onReset: {
                        drag = nil
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
        if let drag { return drag.height }
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
