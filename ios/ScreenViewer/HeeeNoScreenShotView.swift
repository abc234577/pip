//
//  HeeeNoScreenShotView.swift
//  防截图视图容器。
//
//  来源：开源库 HeeeShare/HeeeNoScreenShotView
//        https://github.com/HeeeShare/HeeeNoScreenShotView
//  原理：把内容放进 UITextField(isSecureTextEntry = true) 的内部安全画布。
//        系统级截图 / 录屏 / AirPlay 镜像里，该画布内容为黑/空，从而达到防截图。
//        内容在设备本地屏幕上仍然正常可见。
//  注意：仅适用于 iOS 13 及以后系统（本项目部署目标 16.5，满足）。
//
//  用法：把它当普通 UIView 用，直接 addSubview，子视图会被自动塞进安全画布并铺满：
//      let secure = HeeeNoScreenShotView()
//      secure.addSubview(yourContentView)
//

import UIKit

final class HeeeNoScreenShotView: UIView {

    /// 承载安全画布的 secure 文本框。
    private let textField: UITextField = {
        let tf = UITextField()
        tf.isSecureTextEntry = true
        tf.isUserInteractionEnabled = false
        return tf
    }()

    /// 真正的内容承载层（挂在 textField 的内部安全画布里）。
    private let clearView = UIView()

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    init() {
        super.init(frame: .zero)
        setupUI()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        super.addSubview(textField)
        attachClearViewIfNeeded()

        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil)
    }

    /// 抓取 textField 的内部安全画布，把 clearView 挂进去。
    /// 关键修复：这个画布（_UITextLayoutCanvasView）在 init 时刻可能还没创建，
    /// 旧实现只在 setupUI 里尝试一次，拿不到就导致 clearView 永远是孤儿视图，
    /// 内容加进去也不在视图树里 → 全黑。这里做成幂等，并在 layoutSubviews 里
    /// 反复尝试直到成功；拿不到画布时先把 clearView 挂到 self，保证内容不丢失。
    private func attachClearViewIfNeeded() {
        if let canvas = textField.subviews.first {
            if clearView.superview !== canvas {
                canvas.isUserInteractionEnabled = true
                canvas.addSubview(clearView)
            }
        } else if clearView.superview == nil {
            super.addSubview(clearView)
        }
    }

    /// secure 文本框一旦成为第一响应者会弹键盘，这里拦下来并收起，避免误弹。
    @objc private func keyboardWillShow() {
        if textField.isFirstResponder {
            textField.resignFirstResponder()
            textField.subviews.first?.isUserInteractionEnabled = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textField.frame = bounds
        if textField.superview != self {
            super.addSubview(textField)
        }
        // 画布就绪后把 clearView 迁入真正的安全画布（可能本来临时挂在 self 上）。
        attachClearViewIfNeeded()
        clearView.frame = clearView.superview?.bounds ?? bounds
        // 让每个被托管的内容视图始终铺满 clearView（frame 布局，不会被算成 0 尺寸）。
        for sub in clearView.subviews {
            sub.frame = clearView.bounds
        }
    }

    /// 关键：重写 addSubview，把外部加进来的视图统一塞进安全画布 clearView，
    /// 并用 frame + autoresizingMask 让它铺满，彻底不依赖调用方的 Auto Layout，
    /// 避免「子视图约束锚到外层 secureView、真实父视图却是 clearView」的错位黑屏。
    override func addSubview(_ view: UIView) {
        if view == textField {
            super.addSubview(view)
            return
        }
        attachClearViewIfNeeded()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = clearView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clearView.addSubview(view)
        setNeedsLayout()
    }
}
