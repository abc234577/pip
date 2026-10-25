# 从 Windows 打出 IPA(云端 macOS 编译,你不碰 Mac)

本机(Windows)不能直接编译 iOS App。下面用 GitHub Actions 的免费 macOS runner
在云端自动编译,产出可下载的 IPA。两条轨道任选:

- **轨道一(默认开启):免签名 IPA** —— 给越狱 / TrollStore 设备,无需 Apple 账号。
- **轨道二(默认关闭):正规签名 IPA** —— 有付费开发者账号时用。

---

## 一、一次性准备

工程里已放好:
- `ios/project.yml` —— XcodeGen 工程描述(你现在只有散的 .swift,没有 .xcodeproj,云端会自动生成)
- `.github/workflows/ios-ipa.yml` —— 编译+打包流水线
- `ios/ExportOptions.plist` —— 轨道二导出配置

在这台 Windows 上把 `der/` 推到你自己的 GitHub 私有仓库:

```bat
cd /d D:\AI\测试语音\无聊\der
git init
git add .
git commit -m "screen viewer"
git branch -M main
git remote add origin https://github.com/你的用户名/der.git
git push -u origin main
```

(没装 git 就先 https://git-scm.com/download/win 装一下。)

---

## 二、轨道一:拿免签名 IPA(推荐,你手机能 SSH 多半就是这类)

1. push 后,去仓库页面 **Actions** 标签,会看到 `Build iOS IPA` 正在跑(或点 `Run workflow` 手动触发)。
2. 约 5~10 分钟跑完,进这次运行,底部 **Artifacts** 下载 `ScreenViewer-unsigned-ipa`。
3. 解压得到 `ScreenViewer-unsigned.ipa`。
4. 装到手机(二选一):
   - **TrollStore(最省事):** 把 ipa 用 AirDrop / 任意方式传到手机,TrollStore 里点 `+` 选它安装。
   - **SSH 批量:** 用 `der/scripts/install-via-ssh.sh`:
     ```bash
     ./install-via-ssh.sh ScreenViewer-unsigned.ipa <手机IP> root
     ```
     (在 Windows 上用 Git Bash 或 WSL 跑这个脚本;密码按提示输入。)

装好后桌面出现 **ScreenViewer**,打开填 `ws://电脑IP:8080/ws` 连接即可。

---

## 三、轨道二:正规签名 IPA(有 $99 开发者账号时)

1. 导出你的签名证书为 `.p12`,和对应的 `.mobileprovision` 描述文件。
2. 仓库 Settings → Secrets → Actions 添加:
   - `CERT_P12_BASE64` = `base64 证书.p12` 的内容
   - `CERT_PASSWORD` = p12 密码
   - `PROFILE_BASE64` = `base64 描述文件.mobileprovision` 的内容
3. 填好 `ios/ExportOptions.plist` 里的 `teamID` 和描述文件名。
4. 把 `.github/workflows/ios-ipa.yml` 里 `build-signed` 的 `if: ${{ false }}` 改成 `if: ${{ true }}`。
5. push,下载 `ScreenViewer-signed-ipa`,用 Apple Configurator / 爱思助手 装机。

---

## 常见报错对照

| 现象 | 原因 / 处理 |
|---|---|
| Actions 里 `No such module 'WebRTC'` | `project.yml` 的 WebRTC 版本解析失败;把 `from: "125.6422.070"` 换成 stasel/WebRTC 最新 tag |
| `CODE_SIGNING ... required` | 轨道一应全程 `CODE_SIGNING_ALLOWED=NO`,检查没被覆盖 |
| 装上闪退(越狱机) | ldid 权限不够;确认 workflow 里 ldid 那步成功,或用 TrollStore 安装(它会自己重签) |
| xcodegen 报 Info.plist 找不到 | 首次构建会生成,无需手动建;若仍报错在 `ScreenViewer/` 放一个空 Info.plist 占位 |
