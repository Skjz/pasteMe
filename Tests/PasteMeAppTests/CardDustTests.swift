import CoreGraphics
import QuartzCore
import Metal
import Testing
@testable import PasteMeApp

@Suite struct DustTimingTests {
    let timing = DustTiming()

    @Test func forwardRunsFromZeroToDuration() {
        #expect(timing.shaderTime(elapsed: 0, reverse: false) == 0)
        #expect(timing.shaderTime(elapsed: timing.duration + 1, reverse: false) == timing.duration)
        #expect(timing.playLength(reverse: false) == timing.duration)
    }

    @Test func reverseRunsBackFasterAndEndsWithTheWholeCard() {
        #expect(timing.shaderTime(elapsed: 0, reverse: true) == timing.duration)
        #expect(timing.playLength(reverse: true) < timing.duration)
        #expect(timing.shaderTime(elapsed: timing.playLength(reverse: true), reverse: true) == 0)
    }
}

@Suite struct SpringCurveTests {
    @Test(arguments: [SpringCurve.slide, SpringCurve.cursor, SpringCurve.selection])
    func startsAtZeroOvershootsSlightlyAndSettles(_ spring: SpringCurve) {
        #expect(spring.progress(at: 0) == 0)
        let samples = stride(from: 0.0, through: spring.settleTime, by: 0.005).map(spring.progress(at:))
        let peak = samples.max() ?? 0
        #expect(peak > 1 && peak < 1.1)
        #expect(abs(spring.progress(at: spring.settleTime) - 1) < 0.002)
    }
}

extension SpringCurveTests {
    /// 几个空位一起去掉时卡片一次滑过好几格，冲过终点的距离要小于卡片间距，否则会撞进左边的卡片。
    @Test func slidingTenSlotsOvershootsLessThanTheGapBetweenCards() {
        let spring = SpringCurve.slide
        let peak = stride(from: 0.0, through: spring.settleTime, by: 0.002).map(spring.progress(at:)).max() ?? 0
        let tenSlots = 10 * (ClipCardView.size.width + HistoryView.cardSpacing)
        #expect(CGFloat(peak - 1) * tenSlots < HistoryView.cardSpacing)
    }
}

/// 撤销删除时颗粒拼成的卡片要和显示出来的卡片一样大，拼好之前选中项变了也一样。
@MainActor
@Suite struct CardDustScaleTests {
    @Test func scaleFollowsSelectionWithTheCardsSpring() {
        let dust = CardDust()
        var clock: CFTimeInterval = 100
        dust.now = { clock }
        dust.cardLaidOut(1, at: CGRect(x: 30, y: 64, width: 230, height: 240))
        dust.cardLaidOut(2, at: CGRect(x: 278, y: 64, width: 230, height: 240))
        // 和第一次布局在同一次更新里选中：刚出现的卡片直接是放大后的样子。
        dust.selectionChanged(to: 1)
        #expect(dust.scale(of: 1) == HistoryView.selectedScale)
        clock += 1
        #expect(dust.scale(of: 1) == HistoryView.selectedScale)
        #expect(dust.scale(of: 2) == 1)

        dust.selectionChanged(to: 2)

        #expect(dust.scale(of: 1) == HistoryView.selectedScale)
        clock += 0.05
        let shrinking = dust.scale(of: 1)
        #expect(shrinking < HistoryView.selectedScale && shrinking > 1)
        clock += 1
        #expect(dust.scale(of: 1) == 1)
        #expect(dust.scale(of: 2) == HistoryView.selectedScale)
    }
}

/// 卡片补位途中删除时，颗粒要从卡片此刻在屏幕上的位置开始；聚拢途中卡片被挤开时，颗粒跟着走。
@MainActor
@Suite struct CardDustSlideTests {
    let dust = CardDust()
    let slot0 = CGRect(x: 30, y: 64, width: 230, height: 240)
    let slot2 = CGRect(x: 526, y: 64, width: 230, height: 240)

    @Test func layoutChangeRightAfterTheSlideAnimationIsFollowedAlongTheSpring() {
        let clock = Box(100.0)
        dust.now = { clock.value }
        dust.cardLaidOut(1, at: slot2)

        _ = dust.slideAnimation()
        // SwiftUI 晚一帧才报告新位置，这之前卡片还在原处。
        clock.value += 0.01
        #expect(dust.visibleFrame(of: 1) == slot2)
        dust.cardLaidOut(1, at: slot0)

        #expect(abs((dust.visibleFrame(of: 1)?.minX ?? 0) - 526) < 10)
        clock.value += 0.1
        let midway = dust.visibleFrame(of: 1)?.minX ?? 0
        #expect(midway > 30 && midway < 526)
        clock.value += SpringCurve.slide.settleTime
        #expect(dust.visibleFrame(of: 1) == slot0)
    }

    @Test func layoutChangeWithoutSlideAnimationJumps() {
        let clock = Box(100.0)
        dust.now = { clock.value }
        dust.cardLaidOut(1, at: slot2)
        clock.value += 5

        // 例如改了搜索词，列表直接换掉。
        dust.cardLaidOut(1, at: slot0)

        #expect(dust.visibleFrame(of: 1) == slot0)
    }

    @Test func cardsThatLeftHaveNoFrame() {
        dust.cardLaidOut(1, at: slot0)
        dust.cardLeft(1)
        #expect(dust.visibleFrame(of: 1) == nil)
    }
}

/// 测试里可变的时钟。
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// 离屏执行着色器，检查画出的像素。视图 300×300 点、1 倍像素，卡片放在 (35, 30)。
@MainActor
@Suite struct DustShaderTests {
    let viewSize = CGSize(width: 300, height: 300)
    let card = CGRect(x: 35, y: 30, width: 230, height: 240)
    let timing = DustTiming()

    /// 卡片的替身：上面 48 点绿色（标题栏），下面左半红、右半蓝，全部不透明。
    func cardImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 230, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // CGContext 的原点在左下角。
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 115, height: 192))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 115, y: 0, width: 115, height: 192))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 192, width: 230, height: 48))
        return context.makeImage()!
    }

    struct Pixels {
        let width: Int
        let bytes: [UInt8]
        /// BGRA。
        func at(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i + 2], bytes[i + 1], bytes[i], bytes[i + 3])
        }
    }

    func render(time: Double, scale: CGFloat = 1) async throws -> Pixels {
        let pipeline = DustPipeline.shared
        pipeline.prepare()
        for _ in 0..<500 where pipeline.state == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let device = try #require(pipeline.device)
        let texture = try #require(pipeline.texture(from: cardImage()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(viewSize.width), height: Int(viewSize.height), mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let buffer = try #require(pipeline.queue?.makeCommandBuffer())
        let frame = DustFrame(texture: texture, frame: card, scale: scale, timing: timing, time: time, seed: 7)
        #expect(pipeline.encode([frame], viewSize: viewSize, into: target, on: buffer))
        await withCheckedContinuation { continuation in
            buffer.addCompletedHandler { _ in continuation.resume() }
            buffer.commit()
        }

        var bytes = [UInt8](repeating: 0, count: target.width * target.height * 4)
        target.getBytes(&bytes, bytesPerRow: target.width * 4, from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        return Pixels(width: target.width, bytes: bytes)
    }

    @Test func atTheStartTheParticlesFormTheWholeCardWithoutGaps() async throws {
        let pixels = try await render(time: 0)
        var transparentInside = 0
        for y in Int(card.minY)..<Int(card.maxY) {
            for x in Int(card.minX)..<Int(card.maxX) where pixels.at(x, y).a < 250 {
                transparentInside += 1
            }
        }
        #expect(transparentInside == 0)
        // 上下左右没有颠倒。
        #expect(pixels.at(100, 40).g > 250)
        #expect(pixels.at(80, 200).r > 250)
        #expect(pixels.at(220, 200).b > 250)
        // 卡片以外是透明的。
        #expect(pixels.at(20, 150).a == 0)
        #expect(pixels.at(150, 285).a == 0)
    }

    @Test func selectedCardIsDrawnEnlargedAroundItsCenter() async throws {
        let pixels = try await render(time: 0, scale: 1.05)
        // 放大 1.05 倍后左边缘向左移出约 5.75 点。
        #expect(pixels.at(Int(card.minX) - 4, 150).a > 250)
        #expect(pixels.at(Int(card.minX) - 8, 150).a == 0)
    }

    @Test func particlesDriftUpwardsAndAreGoneAtTheEnd() async throws {
        let middle = try await render(time: 0.6)
        var aboveCard = 0
        for y in 0..<Int(card.minY) {
            for x in 0..<Int(viewSize.width) where middle.at(x, y).a > 0 {
                aboveCard += 1
            }
        }
        #expect(aboveCard > 0)

        let end = try await render(time: timing.duration)
        #expect(end.bytes.allSatisfy { $0 == 0 })
    }
}
