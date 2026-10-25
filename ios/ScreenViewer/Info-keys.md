# Info.plist 必填项（建工程后在 Target → Info / Signing & Capabilities 里加）

## 1. 后台模式（画中画必须）
在 Signing & Capabilities 里 `+ Capability` → `Background Modes`，勾选：
- Audio, AirPlay, and Picture in Picture

对应 Info.plist：
```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

## 2. 允许明文/局域网连接（走 ws:// 而非 wss://）
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

## 3. 本地网络权限（iOS 14+ 连局域网设备会弹窗）
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>用于连接并实时观看你的电脑屏幕</string>
```

## 4. 方向（横屏看电脑更舒服，按需）
```xml
<key>UISupportedInterfaceOrientations</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>
```
