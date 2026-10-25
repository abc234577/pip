# 远程看屏系统（电脑被看 → iOS 观看）

实时看电脑屏幕 · 任意裁剪 · 画中画小窗 · 防截图保护隐私。
传输用 WebRTC（H264/VP8），局域网直连，延迟通常 <100ms。

```
der/
├─ pc/                        电脑端（被观看方，Windows）
│  ├─ requirements.txt
│  ├─ sender.py               抓屏 + WebRTC 推流 + 自带信令
│  └─ run.bat                 一键装依赖并启动
└─ ios/                       iOS 端（观看方，iOS 16.5）
   ├─ Podfile
   ├─ Info-keys.md            必填的 Info.plist / Capability
   └─ ScreenViewer/           Swift 源码
      ├─ AppDelegate.swift
      ├─ ViewController.swift       主界面：连接/裁剪/画中画按钮
      ├─ SignalingClient.swift      WebSocket 信令
      ├─ WebRTCClient.swift         收 offer→回 answer，取远端帧
      ├─ FrameConverter.swift       RTCVideoFrame→CVPixelBuffer + 裁剪
      ├─ VideoDisplayView.swift     AVSampleBufferDisplayLayer 送显
      ├─ HeeeNoScreenShotView.swift 防截图容器（开源库 HeeeShare/HeeeNoScreenShotView）
      ├─ PiPController.swift        画中画
      └─ CropView.swift             可拖拽裁剪框
```

---

## 一、电脑端（被观看方）

1. 装 Python 3.10/3.11（aiortc 对 3.12 偶有轮子问题，推荐 3.11）。
2. 进 `pc/` 双击 `run.bat`，或手动：
   ```bat
   pip install -r requirements.txt
   python sender.py --host 0.0.0.0 --port 8080 --monitor 1 --fps 30
   ```
3. 终端会打印本机 IPv4，比如 `192.168.1.100`。
4. 参数：
   - `--monitor` 显示器序号，`1`=主屏，多屏改 2/3。
   - `--fps` 帧率，卡就降到 20。
   - `--max-width` 超过就缩放，默认 1920，省带宽。
   - `--crop left,top,w,h` 服务端预裁剪（可选，手机端也能裁）。

防火墙首次会弹窗，允许 Python 的专用/公用网络访问。

---

## 二、iOS 端（观看方，iOS 16.5）

### 建工程
1. Xcode 新建 App，名字 **ScreenViewer**，语言 Swift，最低部署 iOS 16.5，界面选 Storyboard 都行（本项目纯代码，建完把自带的 `ViewController.swift`/`SceneDelegate` 删掉或替换）。
   - 若用了 SceneDelegate 模板：删掉 SceneDelegate，并在 Info.plist 删除 `UIApplicationSceneManifest` 整段，保证走 `AppDelegate` 的 window 启动。
2. 把 `ScreenViewer/` 里的所有 `.swift` 拖进工程（勾 Copy items if needed）。

### 加 WebRTC 依赖（二选一）
- **SPM（推荐）**：File → Add Package Dependencies，填
  `https://github.com/stasel/WebRTC`，选最新版，`import WebRTC`。
- **CocoaPods**：用本目录 `Podfile`，`pod install`，之后开 `.xcworkspace`。

### 配 Capability / Info.plist
照 `ScreenViewer/Info-keys.md` 加：后台模式(Audio/PiP)、本地网络权限、ATS 允许局域网。

### 跑
1. 真机运行（画中画和防截图在模拟器上不完整，必须真机）。
2. 顶部填 `ws://192.168.1.100:8080/ws`（换成你电脑的 IP），点 **连接**。
3. 看到电脑画面后：
   - **裁剪**：点一下出现黄框，拖四角缩放、拖中间平移，画面即按框实时裁剪；再点关闭恢复整屏。
   - **画中画**：点一下进小窗，可拖到任意位置、回桌面悬浮；再点退出。

---

## 三、功能对应实现

| 需求 | 落点 |
|---|---|
| 实时看电脑屏幕 | `pc/sender.py` 抓屏推流 + `WebRTCClient` 接收 |
| 任意裁剪画面大小 | `CropView` 拖拽出归一化矩形 → `FrameConverter` 逐帧裁剪 |
| 画中画小窗 | `PiPController` + `AVSampleBufferDisplayLayer` |
| 电脑端连接 | `sender.py` 自带 WebSocket 信令，主动发 offer |
| iOS 16.5 观看方 | 部署目标 16.5，AVSampleBuffer PiP 自 iOS15 起可用 |
| 防截图保护隐私 | `HeeeNoScreenShotView`：secure 安全画布包住视频层，系统截图/录屏变黑 |

## 四、说明
- **防截图原理**：用开源库 [HeeeNoScreenShotView](https://github.com/HeeeShare/HeeeNoScreenShotView)——把视频层放进 `UITextField(isSecureTextEntry=true)` 的内部安全画布，系统级截图、录屏、AirPlay 镜像对该区域输出黑/空。该库重写了 `addSubview`，直接 `secureView.addSubview(视频层)` 即可，子视图会被自动塞进安全画布。仅支持 iOS 13+（本项目 16.5 满足）。画中画小窗由系统层渲染，截 PiP 窗本身不受此保护，故主界面看屏时隐私最严；需要全程防护就别开 PiP。
- **延迟/清晰**：同一路由器 5GHz 下最顺；掉帧就降 `--fps` 或 `--max-width`。
- **跨网段/公网**：当前为局域网直连（无 STUN/TURN）。要走公网，在 `WebRTCClient` 的 `iceServers` 和 `sender.py` 里加 STUN/TURN，并改信令为 trickle。
