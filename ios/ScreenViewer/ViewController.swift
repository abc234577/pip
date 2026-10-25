import UIKit
import AVFoundation
import WebRTC

final class ViewController: UIViewController {

    private let signaling = SignalingClient()
    private let rtc = WebRTCClient()
    private let converter = FrameConverter()

    private let secureView = HeeeNoScreenShotView()     // 防截图容器（HeeeNoScreenShotView 开源库）
    private let displayView = VideoDisplayView()        // 送显层
    private let cropOverlay = CropView()                // 裁剪框（悬浮在顶层，不被保护，纯交互）
    private var pip: PiPController!

    private let urlField = UITextField()
    private let statusLabel = UILabel()
    private var currentCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var cropEnabled = false
    private var gotFirstFrame = false
    private var wantConnected = false

    override func viewDidLoad() {
        super.viewDidLoad()
        CrashCatcher.breadcrumb("viewDidLoad: begin")
        view.backgroundColor = .black
        CrashCatcher.breadcrumb("viewDidLoad: before configureAudioSession")
        configureAudioSession()
        CrashCatcher.breadcrumb("viewDidLoad: before layoutUI")
        layoutUI()
        CrashCatcher.breadcrumb("viewDidLoad: before bind")
        bind()
        CrashCatcher.breadcrumb("viewDidLoad: before PiPController")
        pip = PiPController(displayLayer: displayView.displayLayer)
        CrashCatcher.breadcrumb("viewDidLoad: after PiPController")
        // 开屏自动连接：解锁手机点图标后，无需手动输入地址或点连接，直接拉流
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.onConnect()
        }
    }

    private func configureAudioSession() {
        // 画中画必须：playback 分类 + 后台音频能力
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func layoutUI() {
        // 防截图容器铺满安全区
        secureView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secureView)
        NSLayoutConstraint.activate([
            secureView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 80),
            secureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            secureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            secureView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -80),
        ])

        // 视频层加进防截图容器：库重写的 addSubview 会把它塞进内部安全画布，
        // 并用 frame + autoresizingMask 自动铺满。这里【不要】再用 Auto Layout
        // 把 displayView 约束到 secureView —— 它真实父视图是库内部的 clearView，
        // 跨层约束会错位，极易被算成 0 尺寸导致黑屏（这是旧版黑屏的根因之一）。
        secureView.addSubview(displayView)

        // 状态提示叠在视频层之上（连接中/已连接未出帧/断开），避免失败时纯黑无反馈。
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "正在连接电脑…"
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: secureView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: secureView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: secureView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: secureView.trailingAnchor, constant: -20),
        ])

        // 裁剪框叠在上方（默认隐藏）
        cropOverlay.translatesAutoresizingMaskIntoConstraints = false
        cropOverlay.isHidden = true
        view.addSubview(cropOverlay)
        NSLayoutConstraint.activate([
            cropOverlay.topAnchor.constraint(equalTo: secureView.topAnchor),
            cropOverlay.bottomAnchor.constraint(equalTo: secureView.bottomAnchor),
            cropOverlay.leadingAnchor.constraint(equalTo: secureView.leadingAnchor),
            cropOverlay.trailingAnchor.constraint(equalTo: secureView.trailingAnchor),
        ])

        // 顶部地址输入
        urlField.borderStyle = .roundedRect
        urlField.placeholder = "ws://电脑IP:8080/ws"
        urlField.text = "ws://192.168.1.176:8080/ws"
        urlField.autocapitalizationType = .none
        urlField.keyboardType = .URL
        urlField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(urlField)
        NSLayoutConstraint.activate([
            urlField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            urlField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            urlField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            urlField.heightAnchor.constraint(equalToConstant: 40),
        ])

        // 底部按钮：连接 / 裁剪 / 画中画
        let connectBtn = makeButton("连接", #selector(onConnect))
        let cropBtn = makeButton("裁剪", #selector(onCropToggle))
        let pipBtn = makeButton("画中画", #selector(onPiP))
        let stack = UIStackView(arrangedSubviews: [connectBtn, cropBtn, pipBtn])
        stack.distribution = .fillEqually
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func makeButton(_ title: String, _ sel: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 17)
        b.backgroundColor = UIColor.systemBlue
        b.setTitleColor(.white, for: .normal)
        b.layer.cornerRadius = 10
        b.addTarget(self, action: sel, for: .touchUpInside)
        return b
    }

    private func bind() {
        // 信令 -> rtc
        signaling.onOffer = { [weak self] sdp in
            self?.rtc.handleOffer(sdp: sdp)
        }
        signaling.onClose = { [weak self] in
            guard let self = self else { return }
            print("[vc] signaling closed")
            DispatchQueue.main.async {
                guard self.wantConnected else { return }
                self.gotFirstFrame = false
                self.statusLabel.isHidden = false
                self.statusLabel.text = "连接断开，正在重连…"
                // 3 秒后自动重连，避免失败后一直黑屏无反馈。
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self = self, self.wantConnected else { return }
                    self.onConnect()
                }
            }
        }
        rtc.onAnswerReady = { [weak self] sdp in
            self?.signaling.sendAnswer(sdp: sdp)
        }
        // rtc 每帧 -> 裁剪 -> 送显
        rtc.onFrame = { [weak self] frame in
            guard let self = self else { return }
            let crop = self.cropEnabled ? self.currentCrop : nil
            guard let pb = self.converter.pixelBuffer(from: frame, cropRect: crop) else { return }
            DispatchQueue.main.async {
                if !self.gotFirstFrame {
                    self.gotFirstFrame = true
                    self.statusLabel.isHidden = true   // 出第一帧后隐藏提示
                }
                self.displayView.enqueue(pb)
            }
        }
        // 裁剪框 -> 记录归一化矩形
        cropOverlay.onCropChanged = { [weak self] norm in
            self?.currentCrop = norm
        }
    }

    @objc private func onConnect() {
        view.endEditing(true)
        guard let text = urlField.text, let url = URL(string: text) else { return }
        wantConnected = true
        gotFirstFrame = false
        statusLabel.isHidden = false
        statusLabel.text = "正在连接 \(url.host ?? "电脑") …"
        CrashCatcher.breadcrumb("onConnect: before rtc.start")
        rtc.close()
        signaling.disconnect()
        rtc.start()
        CrashCatcher.breadcrumb("onConnect: after rtc.start")
        signaling.connect(url: url)
        CrashCatcher.breadcrumb("onConnect: after signaling.connect")
        // 5 秒还没出帧就提示，方便判断是「连上但没画面」还是「根本没连上」。
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.wantConnected, !self.gotFirstFrame else { return }
            self.statusLabel.text = "已发起连接，但还没收到画面。\n请确认电脑端 sender 已启动、\n地址与局域网 IP 正确。"
        }
    }

    @objc private func onCropToggle() {
        cropEnabled.toggle()
        cropOverlay.isHidden = !cropEnabled
        if !cropEnabled {
            currentCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    @objc private func onPiP() {
        pip.toggle()
    }
}
