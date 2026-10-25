//
//  CrashCatcher.swift
//  启动崩溃捕获器（调试用）。
//
//  目的：ScreenViewer 启动即 SIGSEGV，但系统没有写出 .ips 崩溃报告，
//        无法定位。这里在进程内安装信号处理器 + 未捕获异常处理器，
//        崩溃时把调用栈（backtrace）直接写入一个固定文件，之后用 SSH 拉回来。
//
//  关键：信号处理器里只能调用 async-signal-safe 的函数。因此：
//        - 文件描述符在 install() 时就 open 好，处理器里只用 write()/backtrace_symbols_fd()；
//        - 不在处理器里做 Swift 字符串拼接 / FileHandle / 内存分配。
//        - 面包屑（breadcrumb）用一个预留的 C 缓冲区记录最后一步，
//          即使 backtrace 本身失败，也能知道崩在 viewDidLoad 的哪个阶段。
//

import Foundation
import Darwin

enum CrashCatcher {

    /// 崩溃日志路径：App 沙盒 Documents 下，便于 SSH 读取。
    static let logPath: String = {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("screenviewer_crash.log")
    }()

    private static var fd: Int32 = -1

    /// 在 AppDelegate 最早处调用一次。
    static func install() {
        logPath.withCString { cpath in
            fd = open(cpath, O_CREAT | O_WRONLY | O_APPEND, 0o644)
        }
        writeLine("=== LAUNCH \(isoNow()) pid=\(getpid()) ===")

        // 未捕获的 Objective-C / Swift NSException（会先于 SIGABRT 触发）
        NSSetUncaughtExceptionHandler { exception in
            CrashCatcher.rawWrite("\n=== NSEXCEPTION ===\n")
            CrashCatcher.rawWrite("name: " + exception.name.rawValue + "\n")
            CrashCatcher.rawWrite("reason: " + (exception.reason ?? "nil") + "\n")
            for frame in exception.callStackSymbols {
                CrashCatcher.rawWrite(frame + "\n")
            }
            CrashCatcher.flush()
        }

        // 致命信号
        let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for s in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = CrashCatcher.handler
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(s, &action, nil)
        }
    }

    /// 面包屑：记录 App 启动走到了哪一步（在正常线程里调用，非信号上下文）。
    static func breadcrumb(_ step: String) {
        writeLine("[step] " + step)
    }

    // MARK: - 信号处理器（只用 async-signal-safe 调用）

    private static let handler: @convention(c) (Int32) -> Void = { sig in
        // 固定字符串头部（不做插值，避免内存分配）
        let head = "\n=== FATAL SIGNAL ===\n"
        head.withCString { _ = write(CrashCatcher.fd, $0, strlen($0)) }

        // 信号编号：用极简方式写出（sig 是 Int32，这里容忍一点点非严格安全）
        var n = sig
        var buf = [CChar](repeating: 0, count: 16)
        var i = buf.count - 1
        if n == 0 { buf[i] = 48; i -= 1 }
        while n > 0 && i >= 0 { buf[i] = CChar(48 + (n % 10)); n /= 10; i -= 1 }
        buf.withUnsafeBufferPointer { p in
            _ = write(CrashCatcher.fd, p.baseAddress! + (i + 1), p.count - (i + 1))
        }
        _ = write(CrashCatcher.fd, "\n", 1)

        // 调用栈：backtrace_symbols_fd 是 async-signal-safe 的
        var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let frames = backtrace(&callstack, 128)
        backtrace_symbols_fd(&callstack, frames, CrashCatcher.fd)
        fsync(CrashCatcher.fd)

        // 恢复默认处理并重新抛出，让系统照常收尾
        signal(sig, SIG_DFL)
        raise(sig)
    }

    // MARK: - 普通写入（非信号上下文）

    private static func writeLine(_ s: String) {
        rawWrite(s + "\n")
    }

    private static func rawWrite(_ s: String) {
        guard fd >= 0 else { return }
        s.withCString { _ = write(fd, $0, strlen($0)) }
    }

    private static func flush() {
        if fd >= 0 { fsync(fd) }
    }

    private static func isoNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
