import PasteMeCore
import SwiftUI

/// 光标：选中卡片外面的发光边框，在卡片之间滑动。
struct SelectionCursor: View {
    let style: CursorStyle
    /// 选中卡片标题栏的颜色。
    let color: Color
    /// 焦点在卡片列表上时光标完全不透明，在搜索框时变淡。
    let cardsFocused: Bool
    /// 为 false 时停在当前一帧：面板收起后，或开启了「减少动态效果」。
    let animating: Bool

    /// 光标比卡片向外多出的距离。
    static let outset: CGFloat = 4

    var body: some View {
        TimelineView(.animation(paused: !animating)) { context in
            ring(at: context.date.timeIntervalSinceReferenceDate)
        }
        .opacity(cardsFocused ? 1 : 0.5)
        .allowsHitTesting(false)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12 + Self.outset)
    }

    @ViewBuilder
    private func ring(at time: Double) -> some View {
        switch style {
        case .flow:
            // 一圈渐变每 3 秒转一周，下面垫一层模糊的同样的渐变作为光晕。
            let gradient = AngularGradient(
                colors: [color, .white, color.opacity(0.5), color, .white.opacity(0.85), color],
                center: .center,
                angle: .degrees((time * 120).truncatingRemainder(dividingBy: 360))
            )
            ZStack {
                shape.stroke(gradient, lineWidth: 6).blur(radius: 7).opacity(0.9)
                shape.strokeBorder(gradient, lineWidth: 3)
            }
        case .breathe:
            // 光晕的亮度和范围按 1.6 秒的周期起伏。
            let phase = (sin(time * 2 * .pi / 1.6) + 1) / 2
            shape.strokeBorder(color, lineWidth: 3)
                .shadow(color: color.opacity(0.35 + 0.5 * phase), radius: 3 + 11 * phase)
                .shadow(color: color.opacity(0.25 * phase), radius: 20)
        }
    }
}

extension CursorStyle {
    var title: String {
        switch self {
        case .breathe: "呼吸"
        case .flow: "流光"
        }
    }
}
