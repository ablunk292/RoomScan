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

    /// Where a point in the upright photo (fractions from the top-left) lands in the room,
    /// found by casting a ray from where the camera was when the photo was taken.
    func worldPosition(x: Double, y: Double, in session: ARSession) -> SIMD3<Float>? {
        // The camera sensor is landscape; the photo was turned a quarter turn clockwise.
        let pixelX = Float(y * imageResolution.width)
        let pixelY = Float((1 - x) * imageResolution.height)

        // Ray through that pixel in camera space (x right, y up, looking down -z), then into the room.
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        let cameraDirection = SIMD4<Float>((pixelX - cx) / fx, -(pixelY - cy) / fy, -1, 0)
        let rotated = cameraTransform * cameraDirection
        let worldDirection = simd_normalize(SIMD3<Float>(rotated.x, rotated.y, rotated.z))
        let origin = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            let query = ARRaycastQuery(origin: origin, direction: worldDirection, allowing: target, alignment: .any)
            if let hit = session.raycast(query).first {
                let t = hit.worldTransform.columns.3
                return SIMD3<Float>(t.x, t.y, t.z)
            }
        }
        return nil
    }
}
