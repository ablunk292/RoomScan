import UIKit

/// Item photos, saved as JPEG files in the app's documents folder next to properties.json.
enum ItemPhotos {
    static let directory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// Saves a photo and returns its file name, or nil if it could not be written.
    static func save(_ jpeg: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        do {
            try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            print("ItemPhotos: could not save photo: \(error)")
            return nil
        }
    }

    static func save(_ image: UIImage) -> String? {
        image.jpegData(compressionQuality: 0.8).flatMap { save($0) }
    }

    /// Photos already read from disk. File names are never reused, so entries never go stale.
    private static let cache = NSCache<NSString, UIImage>()

    static func image(named name: String?) -> UIImage? {
        guard let name else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    static func delete(_ name: String?) {
        guard let name else { return }
        cache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// Shrinks a camera photo so a walkthrough with many items stays small.
    static func resized(_ image: UIImage, maxSide: CGFloat = 1600) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
