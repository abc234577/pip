//
//  HeeeNoScreenShotView.swift
//  防截图视图容器。
//
//  来源：开源库 HeeeShare/HeeeNoScreenShotView
//        https://github.com/HeeeShare/HeeeNoScreenShotView
//  原理：把内容放进 UITextField(isSecureTextEntry = true) 的内部安全画布。
//        系统级截图 / 录屏 / AirPlay 镜像里，该画布内容为黑/空，从而达到防截图。
//  注意：仅适用于 iOS 13 及以后系统（本项目部署目标 16.5，满足）。
//
//  用法：把它当普通 UIView 用，直接 addSubview，子视图会被自动塞进安全画布：
//      let secure = HeeeNoScreenShotView()
//      secure.addSubview(yourContentView)
//

import UIKit

final class HeeeNoScreenShotView: UIView {

    /// 承载安全画布的 secure 文本框。
    private let textField: UITextField = {
        let tf = UITextField()
        tf.isSecureTextEntry = true
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
        if let canvas = textField.subviews.first {
            canvas.isUserInteractionEnabled = true
            canvas.addSubview(clearView)
        }

        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil)
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
        clearView.frame = bounds
        if textField.superview != self {
            super.addSubview(textField)
        }
    }

    /// 关键：重写 addSubview，把外部加进来的视图统一塞进安全画布 clearView。
    override func addSubview(_ view: UIView) {
        if view == textField {
            super.addSubview(view)
        } else {
            clearView.addSubview(view)
        }
    }
}
