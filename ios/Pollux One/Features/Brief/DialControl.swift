import SwiftUI
import UIKit

/// ④ 的拨盘本体：一个二维拖拽区。
/// 纵轴是时长（往上更长），横轴是调性（往右更专业）。
/// 时长**吸在档位上**，每落进一档给一次轻触感——段落感靠触觉落地，
/// 这就是「调相机拨盘」的手感来源。
struct DialControl: View {
    @Binding var dial: DialState

    private let haptics = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                grid(in: geo.size)
                anchorDot(.casualMinute, in: geo.size)
                anchorDot(.professionalThreeMinutes, in: geo.size)
                knob(in: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in move(to: value.location, in: geo.size) }
            )
        }
        .frame(height: 260)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottom) { axisLabels }
        .padding(.horizontal, 24)
        .onAppear { haptics.prepare() }
    }

    // MARK: 坐标换算

    private func position(in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(dial.register) * size.width,
                y: (1 - durationFraction(dial.durationSec)) * size.height)
    }

    private func durationFraction(_ seconds: Int) -> CGFloat {
        let low = CGFloat(DialState.durationSteps[0])
        let high = CGFloat(DialState.maxDurationSec)
        return (CGFloat(seconds) - low) / (high - low)
    }

    private func move(to point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let before = dial.durationSec

        dial.setRegister(Double(min(1, max(0, point.x / size.width))))

        let fraction = 1 - min(1, max(0, point.y / size.height))
        let low = CGFloat(DialState.durationSteps[0])
        let high = CGFloat(DialState.maxDurationSec)
        dial.setDuration(seconds: Int((low + fraction * (high - low)).rounded()))

        // 只在真的跨过一档时响，不然拖动全程都在震。
        if dial.durationSec != before { haptics.impactOccurred() }
    }

    // MARK: 画面

    private func grid(in size: CGSize) -> some View {
        ForEach(DialState.durationSteps, id: \.self) { step in
            Rectangle()
                .fill(.quaternary)
                .frame(height: step == dial.durationSec ? 1.5 : 0.5)
                .offset(y: (1 - durationFraction(step)) * size.height)
        }
    }

    private func anchorDot(_ anchor: DialAnchor, in size: CGSize) -> some View {
        var probe = DialState()
        probe.snap(to: anchor)
        let x = CGFloat(probe.register) * size.width
        let y = (1 - durationFraction(probe.durationSec)) * size.height

        return Button {
            dial.snap(to: anchor)
            haptics.impactOccurred()
        } label: {
            VStack(spacing: 4) {
                Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 15, height: 15)
                Text(anchorTitle(anchor))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(width: 88)
        }
        .buttonStyle(.plain)
        .offset(x: min(size.width - 44, max(-44, x - 44)), y: y - 7.5)
    }

    private func anchorTitle(_ anchor: DialAnchor) -> String {
        switch anchor {
        case .casualMinute: "60s 通俗"
        case .professionalThreeMinutes: "3min 偏专业"
        }
    }

    private func knob(in size: CGSize) -> some View {
        let p = position(in: size)
        return Circle()
            .fill(.tint)
            .frame(width: 26, height: 26)
            .shadow(radius: 3, y: 1)
            .offset(x: min(size.width - 13, max(-13, p.x - 13)), y: p.y - 13)
            .animation(.snappy(duration: 0.14), value: dial)
    }

    private var axisLabels: some View {
        HStack {
            Text("通俗")
            Spacer()
            Text("专业")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
    }
}
