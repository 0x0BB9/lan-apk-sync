# LAN APK Sync

在隔离网络内，把 Mac 本地构建的 APK 通过同一 Wi-Fi 发送给 Android 手机。手机只需浏览器，无需安装接收端 APP。

## 使用

1. Mac 和 Android 手机连接同一个 Wi-Fi。
2. 打开 `LAN APK Sync.app`，选择单个 APK；如需自动跟随新构建，选择 `build/app/outputs/flutter-apk` 目录。
3. 点击“开始同步”，首次运行时允许 macOS 接收入站连接。
4. 用手机相机扫描二维码，在浏览器中下载 APK。
5. 打开下载文件，按 Android 系统提示确认安装或更新。

手机首次从该浏览器安装 APK 时，Android 可能要求允许该浏览器“安装未知应用”。普通桌面工具不能绕过系统确认进行静默安装。

## 本地运行与构建

```bash
cd lan-apk-sync
flutter pub get --offline --enforce-lockfile
flutter run -d macos
```

构建 Release：

```bash
flutter build macos --release
```

产物：

```text
build/macos/Build/Products/Release/LAN APK Sync.app
```

## 验证

```bash
flutter analyze
flutter test
flutter build macos --debug
flutter build macos --release
```

## 网络与安全边界

- 服务默认监听 Mac 的 TCP `8787`，可在界面修改。
- 每次启动生成新的随机访问令牌；未持有完整二维码或 URL 的设备无法访问 APK。
- 只共享当前选中的 APK，不提供目录浏览，不上传外网。
- APK 使用明文 HTTP 在局域网传输；页面同时展示 SHA-256，敏感环境仍应使用受控 Wi-Fi。
- 点击“停止同步”或退出 APP 后，下载地址立即失效。

若手机打不开页面，检查两台设备是否在同一子网、Wi-Fi 是否启用了客户端隔离，以及 macOS 防火墙是否允许该 APP 接收入站连接。
