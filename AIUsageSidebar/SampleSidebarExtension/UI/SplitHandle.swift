import AppKit
import SwiftUI

/// The draggable divider between the workspace list and the usage panel.
///
/// The handle is 7pt tall but draws a 1pt line, because a hairline divider is
/// too small a target to grab reliably.
struct SplitHandle: View {
    /// Called with the pointer movement since the drag began.
    let onDrag: (CGFloat) -> Void
    /// Called when a drag ends, and on double click to restore automatic sizing.
    let onDragEnded: () -> Void
    let onReset: () -> Void

    @State private var isActive = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
            Rectangle()
                .fill(isActive ? Color.accentColor : Color.primary.opacity(0.12))
                .frame(height: isActive ? 2 : 1)
        }
        .frame(height: 7)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    // Assigning `@State` invalidates the view whether or not the
                    // value changed, so only announce the transition once. This
                    // fires per pointer event, and a spare layout pass on each
                    // one is visible as jitter in the panel below.
                    if !isActive { isActive = true }
                    // The pointer outruns a 7pt strip, so keep re-asserting the
                    // cursor for as long as the gesture owns it.
                    NSCursor.resizeUpDown.set()
                    onDrag(value.translation.height)
                }
                .onEnded { _ in
                    isActive = false
                    NSCursor.arrow.set()
                    onDragEnded()
                }
        )
        .onTapGesture(count: 2, perform: onReset)
        // The pointer must say "this is draggable" before the user tries.
        //
        // `set()` rather than `push()`/`pop()`: the stack leaks an entry if the
        // view goes away while hovered, which strands every other view with a
        // resize cursor. `onContinuousHover` re-sets on each move, so AppKit's
        // own cursor rects cannot win it back mid-hover.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.resizeUpDown.set()
            case .ended:
                // A drag routinely leaves the strip. Restoring the arrow here
                // would strobe the cursor for the rest of the gesture.
                if !isActive { NSCursor.arrow.set() }
            }
        }
        .help("Drag to resize · double-click to fit the workspace list")
    }
}
