import ImageIO
import SwiftUI

/// An app's icon, as the app's server gives it (`load`, by `id`); a
/// placeholder until it comes, or when there is none.
struct AppIconView: View {
    let id: String?
    var size: CGFloat = 44
    let load: (String) async -> Data?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable()
            } else {
                RoundedRectangle(cornerRadius: size * 0.225).fill(.quaternary)
                    .overlay { Image(systemName: "app.dashed").foregroundStyle(.secondary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225))
        .task(id: id) {
            guard let id, let data = await load(id) else { return }
            image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                return IconImage.filling(decoded)
            }.value
        }
    }
}
