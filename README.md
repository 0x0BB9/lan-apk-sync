# LAN APK Sync

Mac 监听 APK 输出目录，同一 Wi-Fi 内的 Android 手机通过固定下载页获取最新版。运行时不需要外网，手机使用自带浏览器即可。

## 首次配置

1. 在路由器中给 Mac 保留固定的局域网 IP；Mac 和手机连接同一可互通的局域网。
2. 打开 `LAN APK Sync.app`，点击“监听输出目录”，选择具体应用、具体渠道的 APK 目录，例如 Flutter 项目的 `build/app/outputs/flutter-apk`。目录可以暂时没有 APK。
3. 点击“开始同步”，按系统提示允许本地网络访问和防火墙入站连接。默认端口为 TCP `8787`。
4. 手机首次打开完整下载地址，可以扫码、输入或从局域网消息中复制。将页面收藏，或在浏览器支持时添加到手机桌面。
5. 开发正常打包；工具每 2 秒检查目录，文件至少稳定 2 秒且 SHA-256 计算前后未变化时才发布。

## 日常使用

- 开发：把新 APK 构建到同一目录，保持 Mac 工具运行。
- 测试：打开保存的入口 → 下载 APK → 打开文件 → 按 Android 提示安装或更新。首次可能需要允许浏览器“安装未知应用”。
- 重启工具：默认自动恢复目录权限、端口和分享链接，重新开始同步；可以关闭“下次打开自动开始同步”。这不等于开机自启动。
- 目录暂时为空或 APK 正在写入：服务仍可打开，手机页面等待新构建并自动更新。页面需要保持打开；没有后台推送或静默安装。

**固定链接要求 Mac IP、端口和访问令牌均不变。** 切换网络或更换 IP 后需要恢复原地址或重新保存链接。停止同步期间入口不可用，再次启动后同一地址恢复；“重置分享链接”则立即作废旧链接。

## 迁移到隔离环境

优先复制构建好的应用，无需在隔离 Mac 安装 Flutter、Dart 或下载依赖。打包和验收步骤见 [隔离环境使用说明](docs/OFFLINE.md)。

联网开发机生成迁移包：

```bash
bash scripts/package_macos.sh
```

输出在 `dist/`：ZIP、SHA-256 校验文件，以及包含 `.app` 和使用说明的目录。不包含 APK、个人设置、访问令牌、SDK 或依赖缓存。

## 源码开发与验证

当前锁文件使用 Flutter `3.27.4` / Dart `3.6.2`；需要可用的 Xcode macOS 工具链。

```bash
flutter pub get --offline --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter build macos --debug --no-pub
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/macos
flutter build macos --release --no-pub
```

原生测试命令中的 `arch=arm64` 用于 Apple Silicon 开发机；Intel 开发机使用 `arch=x86_64`。Release 产物位于 `build/macos/Build/Products/Release/LAN APK Sync.app`。`--offline` 解析依赖需要本机已有与锁文件匹配的缓存。

## 网络与数据

- 只共享当前 APK，不提供目录浏览，不调用外网服务；下载页不加载外部脚本、字体或图片。
- 每台 Mac 首次生成随机访问令牌，保存在该用户的应用偏好中；完整链接是访问凭据，请只分享给测试人员。可手动重置。
- 文件访问权限使用只读安全书签保存在本机，重新打开应用时恢复；权限失效时提示重新选择目录。
- APK 通过局域网 HTTP 传输，页面显示 SHA-256；传输记录仅保留在本次运行内。
- 手机无法访问时，检查 Mac 工具是否运行、IP/端口是否变化、macOS 本地网络与防火墙权限，以及 Wi-Fi 是否启用了客户端隔离。
