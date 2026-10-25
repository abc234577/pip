import Foundation

/// 极简 WebSocket 信令：收电脑发来的 offer，回 answer。
final class SignalingClient: NSObject {
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default,
                                          delegate: self, delegateQueue: .main)

    var onOffer: ((String) -> Void)?
    var onClose: (() -> Void)?

    func connect(url: URL) {
        task = session.webSocketTask(with: url)
        task?.resume()
        receive()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func sendAnswer(sdp: String) {
        let payload = ["type": "answer", "sdp": sdp]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { err in
            if let err = err { print("[signal] send answer err:", err) }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                print("[signal] recv err:", err)
                self.onClose?()
            case .success(let msg):
                if case let .string(text) = msg,
                   let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["type"] as? String == "offer",
                   let sdp = obj["sdp"] as? String {
                    self.onOffer?(sdp)
                }
                self.receive()
            }
        }
    }
}

extension SignalingClient: URLSessionWebSocketDelegate {
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol p: String?) {
        print("[signal] connected")
    }
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?()
    }
}
