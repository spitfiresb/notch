import SwiftUI

/// Approved character study: the same flat 20 × 24 pixel coordinates as sprite.js.
enum CodexPose { case idle, thinking, running, complete, permission, question, compacting, ko, interrupted, done }

struct CodexSprite: View {
    var pose: CodexPose
    var time: TimeInterval = 0
    var height: CGFloat = 15
    /// Toast choreography supplies its own bob, rotation, and floating glyph.
    var animateBody = true
    var speech = true

    static func width(forHeight height: CGFloat) -> CGFloat { height * 20 / 24 }

    var body: some View {
        Canvas { context, _ in
            var ctx = context
            let p = height / 24
            ctx.scaleBy(x: p, y: p)
            let t = max(0, time)
            let running = pose == .running || pose == .complete
            let frame = Int(t / 0.085) % 4
            var bob: Double = running ? (frame % 2 == 1 ? -0.5 : 0) : pose == .thinking ? sin(t * 3) * 0.35 : 0
            if pose == .permission {
                let q = t.truncatingRemainder(dividingBy: 0.7) / 0.7
                bob = q < 0.35 ? -2 * sin(q / 0.35 * .pi) : 0
            }
            if animateBody {
                if pose == .question {
                    ctx.translateBy(x: 10, y: 20)
                    ctx.rotate(by: .radians(sin(t / 0.9 * .pi * 2) * 0.10))
                    ctx.translateBy(x: -10, y: -20)
                }
                if pose == .compacting {
                    let k = 1 - max(0, sin(t * 3)) * 0.06
                    ctx.translateBy(x: 0, y: 24 * (1 - k)); ctx.scaleBy(x: 1, y: k)
                }
                ctx.translateBy(x: 0, y: bob)
            }
            func color(_ hex: UInt32) -> Color {
                Color(red: Double((hex >> 16) & 255) / 255,
                      green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
            }
            let outline = color(0x222747), shadow = color(0x3d4d9a), blue = color(0x607ce0)
            let light = color(0x88a7ff), shine = color(0xa1bbff), screen = color(0x252c59)
            let cyan = color(0xb4f2f4), amber = color(0xffd18a), red = color(0xff9fad)
            func r(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: Color) {
                ctx.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(c),
                         style: FillStyle(antialiased: false))
            }
            let spans = [(6,4),(4,10),(3,13),(2,15),(1,17),(0,19),(0,20),(0,20),(0,20),(1,18),(1,18),(2,16),(3,14),(4,12)]
            for (j, s) in spans.enumerated() { r(s.0, j, s.1, 1, outline) }
            r(12,0,3,1,outline); r(11,1,5,1,outline)
            let fills = [(6,4),(4,10),(3,13),(2,15),(1,17),(1,18),(1,18),(1,18),(2,16),(2,16),(3,14),(4,12)]
            for (j,s) in fills.enumerated() { r(s.0,j+1,s.1,1,j < 3 ? light : j > 9 ? shadow : blue) }
            r(12,1,3,1,light); r(5,1,5,1,shine); r(12,2,2,1,shine); r(2,5,1,4,light)
            r(17,6,1,4,shadow); r(4,12,12,1,shadow)
            r(5,5,10,1,outline); r(4,6,12,6,outline); r(5,6,10,5,screen); r(5,6,1,1,shadow)
            switch pose {
            case .ko:
                for a in [6,11] { r(a,7,1,1,red); r(a+2,7,1,1,red); r(a+1,8,1,1,red); r(a,9,1,1,red); r(a+2,9,1,1,red) }
            case .permission: r(9,6,2,3,amber); r(9,10,2,1,amber)
            case .question: r(8,6,3,1,cyan); r(11,7,1,1,cyan); r(9,8,2,1,cyan); r(9,10,1,1,cyan)
            case .done, .complete:
                r(6,7,2,1,cyan); r(12,7,2,1,cyan); r(8,9,4,1,cyan); r(7,8,1,1,cyan); r(12,8,1,1,cyan)
            case .compacting:
                for i in 0..<3 { r(6+i*3,8,2,1,Int(t*5)%3 == i ? cyan : shadow) }
            case .interrupted: r(7,8,6,1,shadow)
            case .idle where t.truncatingRemainder(dividingBy: 4) > 3.75:
                r(6,8,3,1,cyan); r(11,8,3,1,cyan)
            default:
                r(6,7,1,1,cyan); r(7,8,1,1,cyan); r(6,9,1,1,cyan)
                if pose != .thinking || Int(t*2)%2 == 0 { r(11,9,3,1,cyan) }
            }
            r(7,14,6,1,outline); r(6,15,8,5,outline); r(7,15,6,4,blue); r(7,15,6,1,light); r(8,19,4,1,shadow)
            r(8,16,1,1,cyan); r(9,17,1,1,cyan); r(8,18,1,1,cyan); r(11,18,1,1,cyan)
            let left = running ? (frame < 2 ? -1 : 1) : 0
            let right = -left
            r(4,15+left,2,5,outline); r(4,16+left,1,3,blue); r(3,18+left,2,2,outline); r(3,18+left,1,1,light)
            r(14,15+right,2,5,outline); r(15,16+right,1,3,blue); r(15,18+right,2,2,outline); r(16,18+right,1,1,light)
            r(6+left,20,3,3,outline); r(6+left,20,2,2,blue); r(5+left,22,4,1,outline); r(5+left,21,1,1,shadow)
            r(11+right,20,3,3,outline); r(12+right,20,2,2,blue); r(11+right,22,4,1,outline); r(14+right,21,1,1,shadow)
            if speech, pose == .permission, Int(t/0.35)%2 == 0 { r(9,-6,2,3,amber); r(9,-2,2,1,amber) }
            if speech, pose == .question { r(8,-6,3,1,cyan); r(11,-5,1,1,cyan); r(9,-4,2,1,cyan); r(9,-2,1,1,cyan) }
        }
        .frame(width: Self.width(forHeight: height), height: height)
    }
}
