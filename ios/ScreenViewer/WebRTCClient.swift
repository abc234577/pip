import Foundation
import WebRTC

/// WebRTC 接收端：吃电脑的 offer，产出 answer，把远端视频帧回调出来。
final class WebRTCClient: NSObject {

    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }()

    private var pc: RTCPeerConnection?
    /// 自定义渲染器：把每一帧 RTCVideoFrame 丢给上层做裁剪+送显。
    private let frameSink = FrameSink()

    /// 每来一帧回调（已是 RTCVideoFrame，上层转 CVPixelBuffer）。
    var onFrame: ((RTCVideoFrame) -> Void)? {
        get { frameSink.onFrame }
        set { frameSink.onFrame = newValue }
    }

    var onAnswerReady: ((String) -> Void)?

    func start() {
        let config = RTCConfiguration()
        config.iceServers = []                       // 纯局域网直连，不需要 STUN
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.continualGatheringPolicy = .gatherOnce

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = WebRTCClient.factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }

    /// 收到 offer -> setRemote -> createAnswer -> setLocal -> 等 ICE 收完 -> 回 answer
    func handleOffer(sdp: String) {
        let offer = RTCSessionDescription(type: .offer, sdp: sdp)
        pc?.setRemoteDescription(offer) { [weak self] err in
            guard let self = self, err == nil else { print("setRemote err:", err as Any); return }
            let cons = RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveVideo": "true"],
                optionalConstraints: nil)
            self.pc?.answer(for: cons) { answer, err in
                guard let answer = answer, err == nil else { print("answer err:", err as Any); return }
                self.pc?.setLocalDescription(answer) { _ in
                    self.waitIceThenSend()
                }
            }
        }
    }

    private var iceSent = false
    private func waitIceThenSend() {
        // gatherOnce + 轮询；完成或 3s 超时就把当前 localDescription 发出去
        func check() {
            guard let pc = self.pc, !self.iceSent else { return }
            if pc.iceGatheringState == .complete, let sdp = pc.localDescription?.sdp {
                self.iceSent = true
                self.onAnswerReady?(sdp)
            }
        }
        check()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self, !self.iceSent, let sdp = self.pc?.localDescription?.sdp else { return }
            self.iceSent = true
            self.onAnswerReady?(sdp)
        }
    }

    func close() {
        pc?.close()
        pc = nil
        iceSent = false
    }

    // 远端 track 到来时挂上渲染器
    private func attach(_ track: RTCVideoTrack) {
        track.add(frameSink)
    }
    fileprivate func onRemoteVideoTrack(_ track: RTCVideoTrack) { attach(track) }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                        streams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            onRemoteVideoTrack(track)
        }
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("[rtc] ice:", newState.rawValue)
    }
    // 其余 delegate 空实现
    func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd s: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove s: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didGenerate c: RTCIceCandidate) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove c: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen d: RTCDataChannel) {}
}

/// RTCVideoRenderer 适配器，把帧透出去。
private final class FrameSink: NSObject, RTCVideoRenderer {
    var onFrame: ((RTCVideoFrame) -> Void)?
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame = frame else { return }
        onFrame?(frame)
    }
}
