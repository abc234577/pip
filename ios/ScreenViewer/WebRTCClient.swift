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
        CrashCatcher.breadcrumb("rtc.start: pc created=\(pc != nil)")
    }

    /// 收到 offer -> setRemote -> createAnswer -> setLocal -> 等 ICE 收完 -> 回 answer
    func handleOffer(sdp: String) {
        let hasVideoM = sdp.contains("m=video")
        CrashCatcher.breadcrumb("handleOffer: len=\(sdp.count) hasVideoM=\(hasVideoM)")
        let offer = RTCSessionDescription(type: .offer, sdp: sdp)
        pc?.setRemoteDescription(offer) { [weak self] err in
            guard let self = self else { return }
            if let err = err { CrashCatcher.breadcrumb("setRemote ERR \(err)"); return }
            CrashCatcher.breadcrumb("setRemote ok")
            let cons = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            self.pc?.answer(for: cons) { answer, err in
                guard let answer = answer, err == nil else { CrashCatcher.breadcrumb("answer ERR \(String(describing: err))"); return }
                CrashCatcher.breadcrumb("answer created len=\(answer.sdp.count)")
                self.pc?.setLocalDescription(answer) { serr in
                    CrashCatcher.breadcrumb("setLocal done err=\(String(describing: serr))")
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
        remoteVideoTrack?.remove(frameSink)
        remoteVideoTrack = nil
        attached = false
        pc?.close()
        pc = nil
        iceSent = false
    }

    // 远端 track 到来时挂上渲染器
    // 【黑屏根因】RTCVideoTrack 这个 ObjC 包装对象在 dealloc 时会把自己 add 过的所有
    // renderer 从底层 native track 上 RemoveSink。旧代码只把 track 当参数传进来、没有强引用，
    // 回调一结束包装对象就被释放 → frameSink 被摘掉 → renderFrame 永远不会被调用。
    // 必须强持有远端 track，直到连接关闭。
    private var remoteVideoTrack: RTCVideoTrack?
    private var attached = false
    private func attach(_ track: RTCVideoTrack) {
        if attached, remoteVideoTrack?.trackId == track.trackId { return }  // 避免重复挂载
        track.isEnabled = true
        track.add(frameSink)
        remoteVideoTrack = track
        attached = true
        CrashCatcher.breadcrumb("attach video track -> frameSink added & track RETAINED id=\(track.trackId)")
        startStatsProbe()
    }

    // 诊断：连接后前 20 秒每 2 秒记录一次入站视频统计，便于确认是否真的在解码
    private var statsTicks = 0
    private func startStatsProbe() {
        statsTicks = 0
        func tick() {
            guard let pc = self.pc, self.statsTicks < 10 else { return }
            self.statsTicks += 1
            pc.statistics { report in
                for (_, s) in report.statistics where s.type == "inbound-rtp" {
                    let v = s.values
                    func g(_ k: String) -> String { v[k].map { "\($0)" } ?? "-" }
                    if g("kind") != "video" { continue }
                    CrashCatcher.breadcrumb("stats inbound video: pkts=\(g("packetsReceived")) lost=\(g("packetsLost")) framesRecv=\(g("framesReceived")) framesDecoded=\(g("framesDecoded")) keyFrames=\(g("keyFramesDecoded")) size=\(g("frameWidth"))x\(g("frameHeight")) decoder=\(g("decoderImplementation"))")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { tick() }
    }
    fileprivate func onRemoteVideoTrack(_ track: RTCVideoTrack) { attach(track) }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                        streams: [RTCMediaStream]) {
        let kind = rtpReceiver.track?.kind ?? "nil"
        CrashCatcher.breadcrumb("didAdd rtpReceiver kind=\(kind)")
        if let track = rtpReceiver.track as? RTCVideoTrack {
            onRemoteVideoTrack(track)
        }
    }
    // unified-plan 下更可靠的入轨回调；两条都挂，谁先到用谁
    func peerConnection(_ pc: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        let kind = transceiver.receiver.track?.kind ?? "nil"
        CrashCatcher.breadcrumb("didStartReceivingOn kind=\(kind)")
        if !attached, let track = transceiver.receiver.track as? RTCVideoTrack {
            onRemoteVideoTrack(track)
        }
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        CrashCatcher.breadcrumb("ice state=\(newState.rawValue)")
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        CrashCatcher.breadcrumb("pc state=\(newState.rawValue)")
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
    private var firstFrameLogged = false
    func setSize(_ size: CGSize) {
        CrashCatcher.breadcrumb("renderer setSize \(Int(size.width))x\(Int(size.height))")
    }
    func renderFrame(_ frame: RTCVideoFrame?) {
        if !firstFrameLogged {
            firstFrameLogged = true
            CrashCatcher.breadcrumb("renderFrame FIRST frame=\(frame != nil)")
        }
        guard let frame = frame else { return }
        onFrame?(frame)
    }
}
