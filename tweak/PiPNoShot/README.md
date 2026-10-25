# PiPNoShot — 画中画(PiP)防截图/防录屏插件

让 PiP 悬浮小窗在**截图 / 录屏 / AirPlay 镜像**里变黑，屏幕上正常显示。纯隐私保护。

## 为什么需要插件（App 自己做不到）
App 内用 `isSecureTextEntry` 安全画布能让自己的视频层在截屏里变黑，但 **PiP 悬浮窗是系统 `PIPAgent` 进程**从我们 enqueue 的 `CMSampleBuffer` 重新合成渲染的，安全上下文不跟过去，所以悬浮窗照样能被截。只能在 PIPAgent 进程里动手——这就是本插件。

## 原理
与 `HeeeNoScreenShotView` 同一招，搬进 PIPAgent 执行：在 PiP 内容视图控制器布局时，建一个 `secureTextEntry` 的 `UITextField`，取它的 `_UITextLayoutCanvasView`（寄宿在渲染服务器的 **secure CAContext**）作安全画布，把 PiP 真实内容视图搬进去 → 渲染服务器做截图/录屏/镜像合成时跳过安全上下文 → 悬浮窗变黑。

首版会把命中的类名与视图树 `NSLog` 出来（前缀 `[PiPNoShot]`），装机后据此核对/微调。

## 适配
- 目标：iOS 16.5，rootless 越狱（Dopamine/palera1n）。rootful 见 Makefile 注释。
- SE3 = A15 = arm64e；已同时产 arm64/arm64e。

## 出包方式（任选其一）

### A. GitHub Actions 云端编译（不用 Mac，推荐）
把本仓库推到 GitHub → Actions 自动跑 `Build PiPNoShot deb` → Artifacts 里下 `PiPNoShot-deb`（含 `.deb`）。
手动触发：Actions 页 → `Build PiPNoShot deb` → Run workflow。

### B. 本地 Theos
装好 Theos（`$THEOS`），然后：
```bash
cd tweak/PiPNoShot
make package FINALPACKAGE=1
# 产物在 packages/*.deb
```

## 装到手机
SSH 隧道通了之后（爱思 127.0.0.1:22），用脚本一键推装：
```bat
python ..\..\scripts\install_deb_via_ssh.py 路径\PiPNoShot_0.0.1_iphoneos-arm64.deb --password 你的root密码
```
脚本会 scp 上传 → `dpkg -i` → 重启 PIPAgent/SpringBoard 生效。
或手动：`dpkg -i PiPNoShot*.deb && killall -9 PIPAgent SpringBoard`。

## 验证
手机上开画中画 → 截图或录屏 → PiP 区域应为**黑**，而屏幕上肉眼正常。
看日志（装机后，手机上）：`log stream --predicate 'eventMessage CONTAINS "PiPNoShot"'` 或爱思实时日志，确认 hook 命中的类名与视图树。
