# Android 独立扫码接包端

## 安装与使用

1. 将 `LAN-APK-Receiver-1.0.0.apk` 和同名 `.sha256` 文件复制到隔离环境。在 Mac 校验：

   ```bash
   shasum -a 256 -c LAN-APK-Receiver-1.0.0.apk.sha256
   ```

2. 按测试机允许的本地安装方式，首次安装“局域网接包”。客户端自身也需要先安装；不能用尚未安装的客户端完成首次安装。
3. Mac 和手机连接同一可互通的 Wi-Fi，开启现有 `LAN APK Sync` 共享。Mac `1.1.0` 无需升级。
4. 打开“局域网接包”→“扫描 Mac 二维码”→允许相机→确认开发机地址。入口保存在手机本地；也支持二维码图片识别或手动输入完整链接。
5. 点击“下载并安装”。客户端下载并校验 SHA-256，再打开系统安装器；首次按提示允许“局域网接包”安装未知应用，返回后继续安装。
6. 以后打开客户端即可检查最新包，不必重新扫码。应用保持前台时每 5 秒检查，需手动点击下载与确认安装。

Mac IP、端口和分享令牌不变时入口可复用；Mac 重置链接或更换地址后重新扫码。没有外网的 Wi-Fi 如被系统提示无互联网，请保持连接，不要切到其他网络。

## 安装权限与小米设备

本客户端替代浏览器的扫码和下载功能，不具备静默安装或绕过系统策略的权限。Android 8+ 的安装授权按来源应用管理，改用客户端后仍需要单独授权；详见 [Android 安装授权 API](https://developer.android.com/reference/android/content/pm/PackageManager#canRequestPackageInstalls())。

若 MIUI / HyperOS 在安装客户端、开启未知来源授权或安装测试包时要求小米账号，客户端不能保证免账号；需要设备管理员按该机型策略处理。未在实际小米设备上验证账号提示是否消失。

## 运行与数据范围

- Android 6.0（API 23）及以上；Java 字节码通用 APK，无 CPU 架构专用库。
- ZXing 二维码解码库内置，无浏览器、Google Play 服务、云端识别或首次联网下载模型依赖。相机图像不保存、不上传。
- 只接受 `10.x.x.x`、`172.16.x.x`–`172.31.x.x`、`192.168.x.x` 的 HTTP 分享地址；不解析域名、不跟随 HTTP 重定向。
- 明确使用已连接的 Wi-Fi（或有线局域网）建立连接，不要求网络具备外网访问能力，不使用移动数据、VPN 或 HTTP 代理下载。
- APK 保存到应用私有目录；无需存储、相册全量读取或无障碍权限。图片识别使用系统文件选择器授予的单张图片访问权限。
- 分享入口是访问凭据，保存在应用私有偏好中；禁用云备份和设备迁移。主界面仅展示 IP/端口。可用“忘记当前连接”清除入口。
- SHA-256 用于核对传输完整性，不验证发送者身份。HTTP 未加密，只连接可信 Wi-Fi 与开发机。
- 下载时保持应用在前台；断线、取消或校验失败需重新下载，不支持客户端断点续传。已下载文件可在 Android 应用设置中清除。
- 当前 Release APK 使用内部测试签名，非应用商店生产签名。后续升级需要同一签名密钥；密钥不得提交 Git。

## 联网开发机构建

需要 JDK 17+、Android SDK Platform 36 / build-tools 36.0.0。设置 `JAVA_HOME`、`ANDROID_HOME`；Gradle Wrapper 固定为 `8.14.5`，AGP 为 `8.11.1`。

首次在线填充本机缓存，再对同一 Debug / Release 变体验证离线构建：

```bash
cd android-receiver
./gradlew testDebugUnitTest lintDebug lintRelease assembleDebug assembleRelease \
  --no-daemon --max-workers=2
./gradlew testDebugUnitTest lintDebug lintRelease assembleDebug assembleRelease \
  --offline --no-daemon --max-workers=2
cd ..
bash scripts/package_android.sh
```

产物在 `dist/`：APK、校验文件、使用说明。隔离手机只需 APK；本次不交付 Pub/Gradle 缓存或隔离环境源码重建包，也不改变 Mac Flutter 锁文件。

## 验收

1. 关闭外网，保持手机和 Mac 局域网互通；首次扫码连接应显示 APK 文件名、大小、SHA-256，全程不启动浏览器。
2. 下载并安装；安装授权从设置返回后无需重新下载。系统取消安装时，可再次点击“安装已校验的 APK”。
3. 退出并重新打开客户端，应恢复保存的入口；生成下一版 APK 后，在客户端检查并下载新版。
4. Mac 暂停共享、输出目录为空、重置链接时，应分别显示连接失败、等待构建、入口失效；不能安装未通过校验的文件。

自动化包括 JVM 单元测试、Debug/Release lint、APK 签名验证，以及模拟器上的本地二维码解码、FileProvider 路径限制、真实 Mac 服务下载和安装器 Intent 检查。模拟器检查不替代实体小米设备的相机与系统权限验收。

可选开发者集成检查（仅测试设备；需本机 `adb` / Dart）：

```bash
cd android-receiver
./gradlew assembleDebug assembleDebugAndroidTest --offline --no-daemon
cd ..
APK=android-receiver/app/build/outputs/apk/debug/app-debug.apk
dart run tool/receiver_fixture.dart "$APK" "$(shasum -a 256 "$APK" | awk '{print $1}')"
```

另开终端，指定测试模拟器运行（以下序列号仅为示例）：

```bash
adb -s emulator-5554 install -r android-receiver/app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 install -r android-receiver/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s emulator-5554 shell appops set com.frontsystem.lanapkreceiver REQUEST_INSTALL_PACKAGES allow
adb -s emulator-5554 shell am instrument -w \
  -e endpoint http://10.0.2.2:18787/0123456789abcdefghijklmn/ \
  com.frontsystem.lanapkreceiver.test/com.frontsystem.lanapkreceiver.ReceiverInstrumentation
```

此夹具使用公开的固定测试令牌，仅共享传入的测试 APK。检查完成后在服务终端按 `Ctrl+C` 停止，不能作为实际分发服务长期运行。
