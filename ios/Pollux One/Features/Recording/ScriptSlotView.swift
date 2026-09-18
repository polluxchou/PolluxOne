import SwiftUI

/// 相机 HUD 右下角那一格。判断全在 ScriptSlot 里，这里只负责画。
struct ScriptSlotView: View {
    let slot: ScriptSlot
    let onTap: (BriefScreen) -> Void

    var body: some View {
        Button {
            onTap(slot.destination)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: slot.destination == .handOff ? "plus" : "doc.text")
                    .font(.system(size: 17, weight: .medium))
                Text(slot.caption)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 13))
        }
        .accessibilityLabel(slot.caption)
    }
}
