import AVKit
import AVFoundation

/// 基于 AVSampleBufferDisplayLayer 的画中画小窗（iOS 15+）。
final class PiPController: NSObject {
    private var controller: AVPictureInPictureController?
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init()
        setup()
    }

    private func setup() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            print("[pip] 当前设备不支持画中画")
            return
        }
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self)
        controller = AVPictureInPictureController(contentSource: contentSource)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        controller?.delegate = self
    }

    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }
    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    func toggle() {
        guard let c = controller else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() }
        else { c.startPictureInPicture() }
    }
    func start() { controller?.startPictureInPicture() }
    func stop()  { controller?.stopPictureInPicture() }
}

extension PiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        print("[pip] 启动失败:", error)
    }
}

/// 实时流：把它当作一直在播放、时长无限的直播。
extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController)
        -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        false
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    didTransitionToRenderSize size: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion: @escaping () -> Void) {
        completion()
    }
}
