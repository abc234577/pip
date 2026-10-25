import UIKit

/// 可拖拽的裁剪框，输出归一化矩形 (0~1)。拖四角缩放，拖中间平移。
final class CropView: UIView {
    /// 归一化裁剪区域回调
    var onCropChanged: ((CGRect) -> Void)?

    private let box = UIView()
    private let dim = UIView()           // 框外半透明遮罩
    private var handles: [UIView] = []
    private let handleSize: CGFloat = 28

    // 当前框（本视图坐标系的像素矩形）
    private var rect: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        backgroundColor = .clear

        box.layer.borderColor = UIColor.systemYellow.cgColor
        box.layer.borderWidth = 2
        box.backgroundColor = .clear
        addSubview(box)

        for _ in 0..<4 {
            let h = UIView()
            h.backgroundColor = .systemYellow
            h.layer.cornerRadius = handleSize / 2
            addSubview(h)
            handles.append(h)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        addGestureRecognizer(pan)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if rect == .zero {
            // 初始：居中占 60%
            let w = bounds.width * 0.6, h = bounds.height * 0.6
            rect = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2,
                          width: w, height: h)
        }
        applyRect()
    }

    private func applyRect() {
        box.frame = rect
        let pts = [CGPoint(x: rect.minX, y: rect.minY),
                   CGPoint(x: rect.maxX, y: rect.minY),
                   CGPoint(x: rect.minX, y: rect.maxY),
                   CGPoint(x: rect.maxX, y: rect.maxY)]
        for (i, h) in handles.enumerated() {
            h.frame = CGRect(x: pts[i].x - handleSize/2, y: pts[i].y - handleSize/2,
                             width: handleSize, height: handleSize)
        }
        emit()
    }

    private func emit() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let norm = CGRect(x: rect.minX / bounds.width,
                          y: rect.minY / bounds.height,
                          width: rect.width / bounds.width,
                          height: rect.height / bounds.height)
        onCropChanged?(norm)
    }

    private enum Drag { case none, move, tl, tr, bl, br }
    private var drag: Drag = .none

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            drag = hitTest(p)
        case .changed:
            var r = rect
            switch drag {
            case .move:
                r.origin.x += t.x; r.origin.y += t.y
            case .tl:
                r.origin.x += t.x; r.origin.y += t.y
                r.size.width -= t.x; r.size.height -= t.y
            case .tr:
                r.origin.y += t.y
                r.size.width += t.x; r.size.height -= t.y
            case .bl:
                r.origin.x += t.x
                r.size.width -= t.x; r.size.height += t.y
            case .br:
                r.size.width += t.x; r.size.height += t.y
            case .none: break
            }
            // 约束最小尺寸 + 不越界
            r.size.width = max(40, r.size.width)
            r.size.height = max(40, r.size.height)
            r.origin.x = min(max(0, r.origin.x), bounds.width - r.size.width)
            r.origin.y = min(max(0, r.origin.y), bounds.height - r.size.height)
            rect = r
            applyRect()
            g.setTranslation(.zero, in: self)
        default:
            drag = .none
        }
    }

    private func hitTest(_ p: CGPoint) -> Drag {
        let corners: [(Drag, CGPoint)] = [
            (.tl, CGPoint(x: rect.minX, y: rect.minY)),
            (.tr, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bl, CGPoint(x: rect.minX, y: rect.maxY)),
            (.br, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        for (d, c) in corners {
            if abs(p.x - c.x) < handleSize && abs(p.y - c.y) < handleSize { return d }
        }
        return rect.contains(p) ? .move : .none
    }

    func reset() {
        rect = .zero
        setNeedsLayout()
    }
}
