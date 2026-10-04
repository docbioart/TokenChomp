import SwiftUI

/// Shared vector renderer: no sprite assets, animation framework, or duplicated drawing.
struct Chase: View {
    /// MenuBarExtra labels only display Image and Text, so the menu-bar icon is a rendered frame.
    @MainActor static func iconImage(used: Double?, phase: Double) -> NSImage {
        let size = CGSize(width: (used ?? 0) >= 70 ? 38 : 18, height: 18)
        let renderer = ImageRenderer(content: Chase(used: used, animated: false, icon: true, fixedPhase: phase)
            .frame(width: size.width, height: size.height))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage(size: size)
    }
    var used: Double?
    var animated = true
    var icon = false
    /// Explicit animation phase for off-screen rendering (ImageRenderer has no live timeline).
    var fixedPhase: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: icon ? 0.18 : 0.08, paused: !animated || reduceMotion)) { timeline in
            Canvas { context, size in
                let phase = fixedPhase ?? (animated && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0)
                let radius: CGFloat = icon ? 7 : 12
                let y = size.height / 2
                let fraction = CGFloat((used ?? 0) / 100)
                let x: CGFloat = icon ? size.width - radius - 1 : radius + (size.width - radius * 2) * fraction
                if !icon {
                    let track = Path(roundedRect: CGRect(x: 0, y: y - 2, width: size.width, height: 4), cornerRadius: 2)
                    context.fill(track, with: .color(.primary.opacity(0.08)))
                    // One pellet per ~10pt of rail so narrow rails don't smear into a solid bar.
                    let span = max(0, size.width - 2 * radius)
                    let gaps = max(1, Int(span / 10))
                    for index in 0...gaps {
                        let px = radius + CGFloat(index) * span / CGFloat(gaps)
                        if px > x + radius {
                            context.fill(Path(ellipseIn: CGRect(x: px - 2, y: y - 2, width: 4, height: 4)),
                                         with: .color(.primary.opacity(0.28)))
                        }
                    }
                }
                if let used, used >= 70 {
                    let gap = CGFloat(max(0, (100 - used) / 10))
                    let gx = icon ? radius + 1 : x - radius * (1.2 + gap)
                    ghost(&context, center: CGPoint(x: gx, y: y + CGFloat(sin(phase * 5)) * (icon ? 0 : 1.5)),
                          radius: radius * 0.9, danger: used >= 90)
                }
                let angle = 8 + (sin(phase * 10) + 1) * 17
                var mouth = Path()
                mouth.move(to: CGPoint(x: x, y: y))
                mouth.addArc(center: CGPoint(x: x, y: y), radius: radius,
                             startAngle: .degrees(angle), endAngle: .degrees(360 - angle), clockwise: false)
                mouth.closeSubpath()
                context.fill(mouth, with: .color(used == nil ? .gray : Color(red: 1, green: 0.78, blue: 0.16)))
                context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - radius * 0.62, width: 2, height: 2)), with: .color(.black.opacity(0.8)))
            }
        }
        .accessibilityHidden(true)
    }
    private func ghost(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, danger: Bool) {
        let x = center.x, y = center.y, r = radius
        var p = Path()
        p.move(to: CGPoint(x: x - r, y: y + r))
        p.addLine(to: CGPoint(x: x - r, y: y))
        p.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: x + r, y: y + r))
        for i in stride(from: 4, through: 0, by: -1) {
            p.addLine(to: CGPoint(x: x - r + CGFloat(i) * r / 2, y: y + r - (i % 2 == 0 ? 0 : r * 0.4)))
        }
        p.closeSubpath()
        context.fill(p, with: .color(danger ? Color(red: 1, green: 0.32, blue: 0.4) : Color(red: 0.64, green: 0.55, blue: 1)))
        for dx in [-0.35, 0.35] {
            let eye = CGRect(x: x + CGFloat(dx) * r - r * 0.2, y: y - r * 0.3, width: r * 0.45, height: r * 0.6)
            context.fill(Path(ellipseIn: eye), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: eye.midX, y: eye.midY - 1, width: r * 0.2, height: r * 0.3)), with: .color(.black))
        }
    }
}
