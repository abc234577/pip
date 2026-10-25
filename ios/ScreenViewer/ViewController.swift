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
    private var currentCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var cropEnabled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureAudioSession()
        layoutUI()
        bind()
        pip = PiPController(displayLayer: displayView.displayLayer)
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

        // 视频层加进防截图容器：库重写了 addSubview，会自动塞进内部安全画布
        displayView.translatesAutoresizingMaskIntoConstraints = false
        secureView.addSubview(displayView)
        NSLayoutConstraint.activate([
            displayView.topAnchor.constraint(equalTo: secureView.topAnchor),
            displayView.bottomAnchor.constraint(equalTo: secureView.bottomAnchor),
            displayView.leadingAnchor.constraint(equalTo: secureView.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: secureView.trailingAnchor),
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
            print("[vc] signaling closed")
            _ = self
        }
        rtc.onAnswerReady = { [weak self] sdp in
            self?.signaling.sendAnswer(sdp: sdp)
        }
        // rtc 每帧 -> 裁剪 -> 送显
        rtc.onFrame = { [weak self] frame in
            guard let self = self else { return }
            let crop = self.cropEnabled ? self.currentCrop : nil
            guard let pb = self.converter.pixelBuffer(from: frame, cropRect: crop) else { return }
            DispatchQueue.main.async { self.displayView.enqueue(pb) }
        }
        // 裁剪框 -> 记录归一化矩形
        cropOverlay.onCropChanged = { [weak self] norm in
            self?.currentCrop = norm
        }
    }

    @objc private func onConnect() {
        view.endEditing(true)
        guard let text = urlField.text, let url = URL(string: text) else { return }
        rtc.close()
        signaling.disconnect()
        rtc.start()
        signaling.connect(url: url)
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
