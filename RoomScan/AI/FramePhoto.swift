import ARKit
import CoreImage
import UIKit

/// A still photo taken from the AR camera, kept together with where the camera was,
/// so points in the photo can be traced back into the room.
struct FramePhoto {
    let jpeg: Data
    // Only the camera's position and lens are kept, not the frame itself:
    // holding on to ARFrames starves the camera of buffers.
    private let cameraTransform: simd_float4x4
    private let intrinsics: simd_float3x3
    private let imageResolution: CGSize

    private static let context = CIContext()

    /// Turns the current camera image upright (the phone is held in portrait) and shrinks it
    /// to a size the AI reads well.
    init?(frame: ARFrame, maxSide: CGFloat = 1568) {
        let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = Self.context.createCGImage(scaled, from: scaled.extent),
              let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7) else { return nil }
        self.jpeg = jpeg
        cameraTransform = frame.camera.transform
        intrinsics = frame.camera.intrinsics
        imageResolution = frame.camera.imageResolution
    }

    /// A close-up of one found item, cut from the photo with some of the room around it so
    /// it is clear where the item is.
    func closeUp(of item: DetectedItem) -> Data? {
        guard let image = UIImage(data: jpeg)?.cgImage else { return nil }
        let width = Double(image.width), height = Double(image.height)
        let left = min(max(min(item.left, item.right), 0), 1)
        let right = min(max(max(item.left, item.right), 0), 1)
        let top = min(max(min(item.top, item.bottom), 0), 1)
        let bottom = min(max(max(item.top, item.bottom), 0), 1)

        // Pad the box by half its size on each side, and never cut less than a third of the photo.
        var boxWidth = max((right - left) * 2, 1.0 / 3)
        var boxHeight = max((bottom - top) * 2, 1.0 / 3)
        boxWidth = min(boxWidth, 1)
        boxHeight = min(boxHeight, 1)
        let centerX = right > left ? (left + right) / 2 : item.x
        let centerY = bottom > top ? (top + bottom) / 2 : item.y
        let originX = min(max(centerX - boxWidth / 2, 0), 1 - boxWidth)
        let originY = min(max(centerY - boxHeight / 2, 0), 1 - boxHeight)

        let rect = CGRect(x: originX * width, y: originY * height, width: boxWidth * width, height: boxHeight * height).integral
        guard let cropped = image.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.8)
    }

    /// The line of sight from where the camera was through a point in the upright photo
    /// (fractions from the top-left).
    func ray(x: Double, y: Double) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        // The camera sensor is landscape; the photo was turned a quarter turn clockwise.
        let pixelX = Float(y * imageResolution.width)
        let pixelY = Float((1 - x) * imageResolution.height)

        // Ray through that pixel in camera space (x right, y up, looking down -z), then into the room.
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        let cameraDirection = SIMD4<Float>((pixelX - cx) / fx, -(pixelY - cy) / fy, -1, 0)
        let rotated = cameraTransform * cameraDirection
        let direction = simd_normalize(SIMD3<Float>(rotated.x, rotated.y, rotated.z))
        let origin = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        return (origin, direction)
    }

    /// Where a point in the upright photo (fractions from the top-left) lands in the room,
    /// found by casting a ray from where the camera was when the photo was taken.
    ///
    /// Ceilings rarely have a detected surface on phones without LiDAR, so when the ray hits
    /// nothing and the floor height is known, the item is placed where the ray meets the floor
    /// (looking down) or a ceiling `ceilingHeight` above it (looking up).
    func worldPosition(x: Double, y: Double, in session: ARSession,
                       floorY: Float? = nil, ceilingHeight: Float = 2.44) -> SIMD3<Float>? {
        let (origin, worldDirection) = ray(x: x, y: y)

        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            let query = ARRaycastQuery(origin: origin, direction: worldDirection, allowing: target, alignment: .any)
            if let hit = session.raycast(query).first {
                let t = hit.worldTransform.columns.3
                return SIMD3<Float>(t.x, t.y, t.z)
            }
        }
        guard let floorY, abs(worldDirection.y) > 0.05 else { return nil }
        let planeY = worldDirection.y < 0 ? floorY : floorY + ceilingHeight
        let distance = (planeY - origin.y) / worldDirection.y
        guard distance > 0, distance < 15 else { return nil }
        return origin + worldDirection * distance
    }
}
