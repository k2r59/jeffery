import SwiftUI
import PhotosUI
import Combine

/// Photo de profil stockée dans l'app (Documents/profile.jpg), redimensionnée à 512 px.
@MainActor
final class ProfileImageStore: ObservableObject {
    static let shared = ProfileImageStore()
    @Published private(set) var image: UIImage?

    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("profile.jpg")
    }

    init() {
        if let data = try? Data(contentsOf: url) { image = UIImage(data: data) }
    }

    func set(_ picked: UIImage) {
        let side: CGFloat = 512
        let scale = side / max(picked.size.width, picked.size.height)
        let size = CGSize(width: picked.size.width * scale, height: picked.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in picked.draw(in: CGRect(origin: .zero, size: size)) }
        image = resized
        try? resized.jpegData(compressionQuality: 0.85)?.write(to: url, options: .atomic)
    }

    func clear() {
        image = nil
        try? FileManager.default.removeItem(at: url)
    }
}

/// Avatar rond : photo si présente, sinon initiale sur fond surface.
struct ProfileAvatar: View {
    @ObservedObject private var store = ProfileImageStore.shared
    var name: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let img = store.image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Text(name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
                    .font(.display(size * 0.42, weight: .black)).foregroundStyle(Theme.citron)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surfaceRaised)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.creme.opacity(0.08), lineWidth: 1))
    }
}
