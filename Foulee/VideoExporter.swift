import UIKit
import AVFoundation
import CoreVideo

enum VideoExportError: LocalizedError {
    case noView
    case snapshot
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .noView: return "L'écran du survol n'est pas prêt."
        case .snapshot: return "Une image du survol n'a pas pu être capturée."
        case .writer(let detail): return "L'encodage de la vidéo a échoué (\(detail))."
        }
    }
}

/// Fabrique une vidéo MP4 image par image à partir d'une vue.
///
/// Contrairement à un enregistrement d'écran, rien n'est filmé « en direct » : chaque image est
/// dessinée, capturée puis encodée avant de passer à la suivante. La vidéo est donc parfaitement
/// fluide, quelle que soit la vitesse de l'iPhone ou de la connexion.
@MainActor
final class FrameVideoWriter {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int

    private let fps: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let renderer: UIGraphicsImageRenderer
    private let pointSize: CGSize
    private var frameCount = 0

    init(view: UIView, fps: Int, url: URL) throws {
        let size = view.bounds.size
        guard size.width > 10, size.height > 10 else { throw VideoExportError.noView }
        let screenScale = view.window?.screen.scale ?? 3
        let scale = min(screenScale, 1080 / size.width)
        let width = Int((size.width * scale / 2).rounded()) * 2
        let height = Int((size.height * scale / 2).rounded()) * 2

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard

        try? FileManager.default.removeItem(at: url)
        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: width * height * 3,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoExpectedSourceFrameRateKey: fps,
        ]
        let colors: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: colors,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                                sourcePixelBufferAttributes: attributes)
        guard assetWriter.canAdd(videoInput) else { throw VideoExportError.writer("format refusé") }
        assetWriter.add(videoInput)
        guard assetWriter.startWriting() else {
            throw VideoExportError.writer(assetWriter.error?.localizedDescription ?? "démarrage")
        }
        assetWriter.startSession(atSourceTime: .zero)

        self.url = url
        self.fps = fps
        pixelWidth = width
        pixelHeight = height
        pointSize = size
        renderer = UIGraphicsImageRenderer(size: size, format: format)
        writer = assetWriter
        input = videoInput
        adaptor = pixelAdaptor
    }

    /// Capture la vue telle qu'elle est affichée et l'ajoute à la vidéo.
    func append(_ view: UIView) async throws {
        var waited = 0
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
            if waited > 4000 { throw VideoExportError.writer("encodeur bloqué") }
        }
        guard let pool = adaptor.pixelBufferPool else { throw VideoExportError.writer("mémoire vidéo") }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { throw VideoExportError.writer("mémoire vidéo") }

        let drawn: Bool = autoreleasepool {
            let bounds = CGRect(origin: .zero, size: pointSize)
            let image = renderer.image { _ in
                view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            guard let cgImage = image.cgImage else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                          width: pixelWidth,
                                          height: pixelHeight,
                                          bitsPerComponent: 8,
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return true
        }
        guard drawn else { throw VideoExportError.snapshot }

        let time = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps))
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw VideoExportError.writer(writer.error?.localizedDescription ?? "ajout d'image")
        }
        frameCount += 1
    }

    func finish() async throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps)))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoExportError.writer(writer.error?.localizedDescription ?? "finalisation")
        }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
