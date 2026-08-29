import SwiftUI

struct EmptyTab: View {
    let symbol: String
    let text: String
    /// Icon only — for the side-dock strip, where a sentence can't fit on a line.
    var compact = false
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.white.opacity(0.3))
            if !compact {
                Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
