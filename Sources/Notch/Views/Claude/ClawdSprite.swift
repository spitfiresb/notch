import SwiftUI

/// Claude Code's pixel mascot, traced from the reference sprite: an 8×6
/// torso with one-pixel arm nubs, single-pixel eyes set right of centre
/// (looking where he's going) and four one-pixel legs, on a 10×7 grid.
/// `.` empty, `#` body, `o`/`x` eye colour.
enum ClawdSprite {
    /// Run cycle: alternate leg pairs.
    static let run: [[String]] = [
        [".########.", ".########.", "###o###o##", "##########", ".########.", ".########.", ".#....#..."],
        [".########.", ".########.", "###o###o##", "##########", ".########.", ".########.", "...#....#."],
    ]
    /// Standing: all four legs down.
    static let stand: [String] =
        [".########.", ".########.", "###o###o##", "##########", ".########.", ".########.", ".#.#..#.#."]
    /// Knocked out: same solid body at 2× resolution so each eye is a 4×4 X.
    static let down: [String] = [
        "..################..",
        "..################..",
        "..################..",
        "..###x##x####x##x#..",
        "######xx######xx####",
        "######xx######xx####",
        "#####x##x####x##x###",
        "..################..",
        "..################..",
        "..################..",
        "..################..",
        "..################..",
        "..##..##....##..##..",
        "..##..##....##..##..",
    ]
    static let columns = 10
    static let rows = 7
    static let body = Color(red: 0xDE / 255, green: 0x88 / 255, blue: 0x6D / 255)

    /// 3×5 speech glyphs shown over his head.
    static let bang: [String] = [".#.", ".#.", ".#.", "...", ".#."]
    static let query: [String] = ["##.", "..#", ".#.", "...", ".#."]

    static func width(forHeight h: CGFloat) -> CGFloat { h * CGFloat(columns) / CGFloat(rows) }
}

/// A bitmap of `.`/`#`/`o`/`x` rows rendered pixel-perfect at `height` points.
struct PixelBitmap: View {
    let bitmap: [String]
    var color: Color = ClawdSprite.body
    var eye: Color = .black
    var height: CGFloat

    private var width: CGFloat {
        height * CGFloat(bitmap.first?.count ?? 1) / CGFloat(bitmap.count)
    }

    var body: some View {
        Canvas { ctx, size in
            let p = size.height / CGFloat(bitmap.count)
            var bodyPath = Path()
            var eyePath = Path()
            for (y, row) in bitmap.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    // Overlap neighbours by a hair so antialiasing can't leave seams.
                    let r = CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p)
                        .insetBy(dx: -0.15, dy: -0.15)
                    if ch == "o" || ch == "x" { eyePath.addRect(r) } else { bodyPath.addRect(r) }
                }
            }
            ctx.fill(bodyPath, with: .color(color))
            ctx.fill(eyePath, with: .color(eye))
        }
        .frame(width: width, height: height)
    }
}
