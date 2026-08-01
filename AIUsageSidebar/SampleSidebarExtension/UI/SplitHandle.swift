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
                    isActive = true
                    onDrag(value.translation.height)
                }
                .onEnded { _ in
                    isActive = false
                    onDragEnded()
                }
        )
        .onTapGesture(count: 2, perform: onReset)
        .onHover { inside in
            // The pointer must say "this is draggable" before the user tries.
            if inside {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Drag to resize · double-click to fit the workspace list")
    }
}
