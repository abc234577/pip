import Foundation
import WebRTC
import CoreImage
import CoreVideo
import Metal
import IOSurface

/// 把 RTCVideoFrame 转成 CVPixelBuffer，并按归一化裁剪矩形裁剪。
final class FrameConverter {
    // 关键修复（启动崩溃根因）：旧代码在存储属性初始化器里直接建 GPU CIContext：
    //     private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    // ViewController() 一构造（AppDelegate didFinishLaunching 阶段）就触发 CoreImage
    // 建立 GPU/Metal 上下文。此刻 App 还没进前台、渲染服务未就绪，CoreImage 内部拿到
    // 空指针 → 启动即 SIGSEGV（崩溃栈确认：FrameConverter.init → CoreImage）。
    // 改为懒加载：裁剪真正用到时（App 早已前台）才创建；优先 Metal，拿不到则退化为纯
    // 软件渲染，保证任何时机/沙盒下都不会崩。裁剪默认关闭，看屏主功能完全不依赖它。
    private var _ciContext: CIContext?
    private var ciContext: CIContext {
        if let c = _ciContext { return c }
        let c: CIContext
        if let dev = MTLCreateSystemDefaultDevice() {
            c = CIContext(mtlDevice: dev)
        } else {
            c = CIContext(options: [.useSoftwareRenderer: true])
        }
        _ciContext = c
        return c
    }

    /// cropRect: 归一化 (0~1) 的 x,y,w,h；nil 表示不裁。
    func pixelBuffer(from frame: RTCVideoFrame, cropRect: CGRect?) -> CVPixelBuffer? {
        guard let src = sourcePixelBuffer(from: frame) else { return nil }
        guard let crop = cropRect, crop != CGRect(x: 0, y: 0, width: 1, height: 1) else {
            return src
        }

        let fullW = CVPixelBufferGetWidth(src)
        let fullH = CVPixelBufferGetHeight(src)
        // CIImage 原点在左下，输入的归一化 y 以左上为基准，这里翻转一次
        let px = max(0, Int(crop.origin.x * CGFloat(fullW)))
        let pw = max(2, Int(crop.width * CGFloat(fullW)))
        let ph = max(2, Int(crop.height * CGFloat(fullH)))
        let pyTop = Int(crop.origin.y * CGFloat(fullH))
        let pyBottom = fullH - pyTop - ph

        let ci = CIImage(cvPixelBuffer: src)
            .cropped(to: CGRect(x: px, y: pyBottom, width: pw, height: ph))
            .transformed(by: CGAffineTransform(translationX: CGFloat(-px),
                                               y: CGFloat(-pyBottom)))

        guard let dst = makeBuffer(width: pw, height: ph) else { return src }
        ciContext.render(ci, to: dst)
        return dst
    }

    private var pathLogged = false
    private func sourcePixelBuffer(from frame: RTCVideoFrame) -> CVPixelBuffer? {
        if let cv = frame.buffer as? RTCCVPixelBuffer {
            if !pathLogged { pathLogged = true; CrashCatcher.breadcrumb("convert path=CVPixelBuffer \(Int(frame.width))x\(Int(frame.height))") }
            return cv.pixelBuffer
        }
        // I420 兜底：转 NV12 CVPixelBuffer
        let i420 = frame.buffer.toI420()
        if !pathLogged { pathLogged = true; CrashCatcher.breadcrumb("convert path=I420 \(Int(i420.width))x\(Int(i420.height)) sY=\(i420.strideY) sU=\(i420.strideU)") }
        let out = i420ToPixelBuffer(i420)
        if out == nil, !failLogged { failLogged = true; CrashCatcher.breadcrumb("i420ToPixelBuffer -> nil") }
        return out
    }

    private func i420ToPixelBuffer(_ b: RTCI420BufferProtocol) -> CVPixelBuffer? {
        let w = Int(b.width), h = Int(b.height)
        guard let pb = makeBuffer(width: w, height: h) else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        // Y 平面
        if let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let ySrc = b.dataY
            for row in 0..<h {
                memcpy(yDst.advanced(by: row * yStride),
                       ySrc.advanced(by: row * Int(b.strideY)), w)
            }
        }
        // UV 交织（NV12）
        if let uvDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let cw = (w + 1) / 2, ch = (h + 1) / 2
            let uSrc = b.dataU, vSrc = b.dataV
            let dst = uvDst.assumingMemoryBound(to: UInt8.self)
            for row in 0..<ch {
                let dRow = dst.advanced(by: row * uvStride)
                let uRow = uSrc.advanced(by: row * Int(b.strideU))
                let vRow = vSrc.advanced(by: row * Int(b.strideV))
                for col in 0..<cw {
                    dRow[col * 2]     = uRow[col]
                    dRow[col * 2 + 1] = vRow[col]
                }
            }
        }
        return pb
    }

    // 3 块环形缓冲：把 IOSurface 占用钉在 3 块以内（WebRTC 解码器会吃掉大量 IOSurface，
    // 每帧新建会触发 -6662 配额上限），并让“正在显示”和“正在写入”的缓冲错开，避免撕裂。
    private var ring: [CVPixelBuffer] = []
    private var ringIdx = 0
    private var ringW = 0, ringH = 0
    private var failLogged = false
    private var logA = false, logB = false, logC = false

    private var diagDone = false
    /// 一次性诊断：逐个尝试几种 IOSurface 创建方式，把每种的返回码写进日志。
    private func diagIOSurface(_ width: Int, _ height: Int) {
        if diagDone { return }
        diagDone = true
        CrashCatcher.breadcrumb("diag MTLDevice=\(MTLCreateSystemDefaultDevice() != nil)")
        let fmts: [(String, OSType)] = [
            ("NV12full", kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            ("NV12video", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            ("BGRA", kCVPixelFormatType_32BGRA)]
        for (name, f) in fmts {
            for (sz, w, h) in [("full", width, height), ("64", 64, 64)] {
                var pb: CVPixelBuffer?
                let a: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                        kCVPixelBufferMetalCompatibilityKey as String: true]
                let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h, f, a as CFDictionary, &pb)
                let hasSurf = pb.map { CVPixelBufferGetIOSurface($0) != nil } ?? false
                CrashCatcher.breadcrumb("diag IOSurf \(name) \(sz) st=\(st) surf=\(hasSurf)")
            }
        }
        let s = IOSurface(properties: [.width: 64, .height: 64,
                                       .pixelFormat: kCVPixelFormatType_32BGRA,
                                       .bytesPerElement: 4])
        CrashCatcher.breadcrumb("diag IOSurface(properties:) 64x64 BGRA -> \(s != nil)")
    }

    private func createOne(_ width: Int, _ height: Int) -> CVPixelBuffer? {
        diagIOSurface(width, height)
        let fmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        // 1) 优先 IOSurface（画中画由系统进程合成，跨进程只认 IOSurface 缓冲）
        var pb: CVPixelBuffer?
        let a: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var st = CVPixelBufferCreate(kCFAllocatorDefault, width, height, fmt, a as CFDictionary, &pb)
        if st == kCVReturnSuccess, let got = pb {
            if !logA { logA = true; CrashCatcher.breadcrumb("buffer=IOSurface \(width)x\(height)") }
            return got
        }
        if !logB { logB = true; CrashCatcher.breadcrumb("IOSurface create FAIL st=\(st) -> plain") }
        // 2) 退到普通内存缓冲（无 IOSurface），ASBDL 仍可显示
        pb = nil
        st = CVPixelBufferCreate(kCFAllocatorDefault, width, height, fmt, nil, &pb)
        if st == kCVReturnSuccess, let got = pb {
            if !logC { logC = true; CrashCatcher.breadcrumb("buffer=plain \(width)x\(height)") }
            return got
        }
        if !failLogged { failLogged = true; CrashCatcher.breadcrumb("plain create FAIL st=\(st) \(width)x\(height)") }
        return nil
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if ring.isEmpty || ringW != width || ringH != height {
            ring.removeAll(); ringW = width; ringH = height; ringIdx = 0
            for _ in 0..<3 { if let b = createOne(width, height) { ring.append(b) } }
            if ring.isEmpty { return nil }
        }
        ringIdx = (ringIdx + 1) % ring.count
        return ring[ringIdx]
    }
}
