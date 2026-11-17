import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'apk_monitor.dart';
import 'apk_share_server.dart';
import 'native_bridge.dart';
import 'share_settings.dart';
import 'shared_apk.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.loadNetworkInterfaces});

  final Future<List<NetworkInterface>> Function()? loadNetworkInterfaces;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _native = NativeBridge();
  final _portController = TextEditingController(text: '8787');
  late final _monitor = ApkMonitor(sha256: _native.sha256);

  ApkShareServer? _server;
  ShareSettings? _settings;
  Timer? _monitorTimer;
  Timer? _networkTimer;
  bool _initializing = true;
  bool _busy = false;
  bool _refreshingApk = false;
  bool _loadingAddresses = false;
  bool _resumePending = false;
  String? _error;
  String? _apkError;
  List<_LanAddress> _addresses = const [];
  _LanAddress? _selectedAddress;
  Uint8List? _qrCode;
  final List<DownloadEvent> _downloads = [];

  SharedApk? get _apk => _monitor.apk;
  String? get _watchedDirectory =>
      _monitor.isDirectory ? _monitor.sourcePath : null;
  bool get _canInteract => !_initializing && !_busy && _settings != null;
  bool get _isRunning => _server?.isRunning ?? false;
  String? get _shareUrl {
    final server = _server;
    final address = _selectedAddress;
    if (server == null || address == null || !server.isRunning) return null;
    return server.urlFor(address.address);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _monitorTimer?.cancel();
    _networkTimer?.cancel();
    unawaited(_server?.stop());
    _portController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      final values = await _native.loadSettings();
      final settings = ShareSettings.fromMap(values);
      // Save the token before publishing any URL, including the first launch.
      await _native.saveSettings(settings);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _portController.text = '${settings.port}';
        final path = values['sourcePath'];
        if (path is String) {
          _monitor.select(path, directory: values['sourceKind'] == 'directory');
        }
        _error = values['sourceError'] as String?;
      });
      await _loadAddresses();
      await _refreshApk();
      if (!mounted) return;
      _startMonitoring();
      _resumePending = settings.autoStart && _monitor.hasSource;
    } on Object catch (error) {
      if (mounted) setState(() => _error = '无法恢复设置：${_errorMessage(error)}');
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
    if (mounted && _resumePending) await _startServer();
  }

  Future<void> _pickSource({required bool directory}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path =
          directory ? await _native.pickDirectory() : await _native.pickApk();
      if (path == null || !mounted) return;
      setState(() {
        _monitor.select(path, directory: directory);
        _apkError = null;
      });
      await _refreshApk();
    } on Object catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startMonitoring() {
    _monitorTimer?.cancel();
    _monitorTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshApk()),
    );
    _networkTimer?.cancel();
    _networkTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      await _loadAddresses();
      if (mounted && _resumePending && _canInteract) await _startServer();
    });
  }

  Future<void> _refreshApk() async {
    if (_refreshingApk || !_monitor.hasSource) return;
    _refreshingApk = true;
    try {
      await _monitor.refresh();
      if (mounted) setState(() => _apkError = null);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _apkError = '读取 APK 失败：${_errorMessage(error)}');
      }
    } finally {
      _refreshingApk = false;
    }
  }

  Future<void> _loadAddresses() async {
    if (_loadingAddresses) return;
    _loadingAddresses = true;
    try {
      final interfaces = await (widget.loadNetworkInterfaces?.call() ??
          NetworkInterface.list(
            type: InternetAddressType.IPv4,
            includeLoopback: false,
            includeLinkLocal: false,
          ));
      final addresses = <_LanAddress>[
        for (final interface in interfaces)
          for (final address in interface.addresses)
            if (_isPrivateIpv4(address.address))
              _LanAddress(interface.name, address.address),
      ]..sort((a, b) {
          final aRank = a.interfaceName == 'en0' ? 0 : 1;
          final bRank = b.interfaceName == 'en0' ? 0 : 1;
          return aRank != bRank
              ? aRank.compareTo(bRank)
              : a.interfaceName.compareTo(b.interfaceName);
        });
      if (!mounted) return;
      setState(() {
        _addresses = addresses;
        if (_selectedAddress == null || !addresses.contains(_selectedAddress)) {
          _selectedAddress = addresses
                  .where(
                      (value) => value.address == _settings?.preferredAddress)
                  .firstOrNull ??
              addresses.firstOrNull;
        }
      });
      await _refreshQrCode();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '无法读取局域网地址：$error');
    } finally {
      _loadingAddresses = false;
    }
  }

  Future<void> _startServer() async {
    if (_isRunning || _busy || _settings == null) return;
    if (!_monitor.hasSource) {
      setState(() => _error = '请先选择 APK 或构建输出目录。');
      return;
    }
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _error = '端口必须是 1024–65535。');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _loadAddresses();
      if (_addresses.isEmpty) {
        throw StateError('未连接局域网，请连接 Wi-Fi 后重试。自动恢复时会等待网络连接。');
      }
      final settings = _settings!.copyWith(
        port: port,
        preferredAddress:
            _settings!.preferredAddress ?? _selectedAddress?.address,
      );
      await _native.saveSettings(settings);
      if (!mounted) return;
      setState(() => _settings = settings);
      final server = ApkShareServer(
        currentApk: () => _apk,
        token: settings.token,
        onDownload: (event) {
          if (!mounted) return;
          setState(() {
            _downloads.insert(0, event);
            if (_downloads.length > 8) _downloads.removeLast();
          });
        },
      );
      await server.start(port: port);
      if (!mounted) {
        await server.stop();
        return;
      }
      setState(() {
        _server = server;
        _resumePending = false;
      });
      await _refreshQrCode();
    } on SocketException catch (error) {
      _resumePending = false;
      if (mounted) {
        setState(() => _error = '无法启动端口 $port：${error.message}');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _errorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopServer() async {
    final server = _server;
    setState(() {
      _server = null;
      _qrCode = null;
      _resumePending = false;
    });
    await server?.stop();
  }

  Future<void> _setAutoStart(bool value) async {
    setState(() => _busy = true);
    try {
      final settings = _settings!.copyWith(autoStart: value);
      await _native.saveSettings(settings);
      if (mounted) {
        setState(() {
          _settings = settings;
          if (!value) _resumePending = false;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectAddress(_LanAddress? value) async {
    if (value == null) return;
    setState(() => _busy = true);
    try {
      final settings = _settings!.copyWith(preferredAddress: value.address);
      await _native.saveSettings(settings);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _selectedAddress = value;
      });
      await _refreshQrCode();
    } on Object catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetShareLink() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置分享链接？'),
        content: const Text('旧链接、手机收藏和桌面快捷方式将失效。重置后需要把新地址保存到手机。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认重置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final settings = _settings!.copyWith(token: newShareToken());
      await _native.saveSettings(settings);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _server?.replaceToken(settings.token);
      });
      await _refreshQrCode();
    } on Object catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshQrCode() async {
    final url = _shareUrl;
    if (url == null) {
      if (mounted) setState(() => _qrCode = null);
      return;
    }
    try {
      final bytes = await _native.qrCode(url);
      if (mounted && url == _shareUrl) setState(() => _qrCode = bytes);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '二维码生成失败：$error');
    }
  }

  Future<void> _copyUrl() async {
    final url = _shareUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('下载地址已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LAN APK Sync'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: _StatusPill(running: _isRunning),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Hero(),
                if (_initializing) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
                if (_error != null || _apkError != null) ...[
                  const SizedBox(height: 16),
                  _ErrorBanner(message: _error ?? _apkError!),
                  if (_settings == null)
                    TextButton(
                      onPressed: _initializing ? null : _initialize,
                      child: const Text('重新加载设置'),
                    ),
                ],
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 820;
                    final source = _buildSourcePanel();
                    final receiver = _buildReceiverPanel();
                    if (!wide) {
                      return Column(
                        children: [
                          source,
                          const SizedBox(height: 18),
                          receiver
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 6, child: source),
                        const SizedBox(width: 18),
                        Expanded(flex: 5, child: receiver),
                      ],
                    );
                  },
                ),
                if (_downloads.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _buildDownloadsPanel(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSourcePanel() {
    final apk = _apk;
    return _Panel(
      title: '1. 选择构建产物',
      subtitle: '首次选择输出目录，后续正常打包即可；目录会自动记住。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed:
                    _canInteract ? () => _pickSource(directory: false) : null,
                icon: const Icon(Icons.android),
                label: const Text('选择 APK'),
              ),
              OutlinedButton.icon(
                onPressed:
                    _canInteract ? () => _pickSource(directory: true) : null,
                icon: const Icon(Icons.folder_open),
                label: const Text('监听输出目录'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: apk == null
                ? Text(
                    _monitor.hasSource
                        ? '等待 APK 生成或写入完成…\n可先开始同步，手机页面会自动更新。'
                        : '尚未选择 APK 或输出目录',
                    style: const TextStyle(color: Color(0xFF64748B)),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(apk.fileName,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(
                          '${formatBytes(apk.size)} · ${_formatTime(apk.modifiedAt)}'),
                      const SizedBox(height: 8),
                      SelectableText(
                        apk.file.path,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF475569)),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        'SHA-256  ${apk.sha256}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
          ),
          if (_watchedDirectory != null) ...[
            const SizedBox(height: 10),
            Text(
              '正在监听：$_watchedDirectory',
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ] else if (_monitor.sourcePath != null) ...[
            const SizedBox(height: 10),
            Text(
              '已记住文件：${_monitor.sourcePath}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ],
          const SizedBox(height: 22),
          const Divider(),
          const SizedBox(height: 18),
          const Text('2. 启动局域网服务',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 140,
                child: TextField(
                  controller: _portController,
                  enabled: !_isRunning && _canInteract,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: '端口'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _isRunning
                    ? OutlinedButton.icon(
                        onPressed: _canInteract ? _stopServer : null,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('停止同步'),
                      )
                    : FilledButton.icon(
                        onPressed: _canInteract ? _startServer : null,
                        icon: const Icon(Icons.wifi_tethering),
                        label: const Text('开始同步'),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('下次打开自动开始同步'),
            subtitle: const Text('恢复上次的目录、端口和分享链接；无需重新选择。'),
            value: _settings?.autoStart ?? true,
            onChanged: _canInteract ? _setAutoStart : null,
          ),
        ],
      ),
    );
  }

  Widget _buildReceiverPanel() {
    final url = _shareUrl;
    return _Panel(
      title: '3. 手机固定入口',
      subtitle: '首次打开后收藏或添加到桌面，以后直接打开下载最新 APK。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_addresses.isNotEmpty)
            DropdownButtonFormField<_LanAddress>(
              value: _selectedAddress,
              decoration: const InputDecoration(labelText: 'Mac 局域网地址'),
              items: [
                for (final address in _addresses)
                  DropdownMenuItem(
                    value: address,
                    child:
                        Text('${address.address}  (${address.interfaceName})'),
                  ),
              ],
              onChanged: _canInteract ? _selectAddress : null,
            )
          else
            const Text('未发现局域网 IPv4 地址。'),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: SelectableText(
              url ?? '开始同步后显示可收藏的下载地址',
              style: const TextStyle(fontSize: 13, color: Color(0xFF475569)),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: url == null ? null : _copyUrl,
            icon: const Icon(Icons.copy),
            label: const Text('复制固定下载地址'),
          ),
          const SizedBox(height: 10),
          const Text(
            '请在路由器中为这台 Mac 保留固定 IP。IP、端口不变且未重置链接时，手机收藏在工具重启后仍然有效。',
            style:
                TextStyle(fontSize: 12, color: Color(0xFF475569), height: 1.5),
          ),
          if (_settings?.preferredAddress != null &&
              _selectedAddress != null &&
              _settings!.preferredAddress != _selectedAddress!.address) ...[
            const SizedBox(height: 8),
            Text(
              'Mac 地址已从 ${_settings!.preferredAddress} 变为 ${_selectedAddress!.address}。旧收藏暂不可用，请恢复原 IP，或保存新地址。',
              style: const TextStyle(color: Color(0xFFB45309), fontSize: 12),
            ),
          ],
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: _canInteract ? _loadAddresses : null,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新网络地址'),
              ),
              TextButton.icon(
                onPressed: _canInteract ? _resetShareLink : null,
                icon: const Icon(Icons.link_off),
                label: const Text('重置分享链接'),
              ),
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('首次连接：也可以扫码打开'),
            children: [
              SizedBox(
                height: 220,
                child: _qrCode == null
                    ? Center(
                        child: Text(_isRunning ? '正在生成二维码…' : '启动服务后显示二维码'))
                    : Padding(
                        padding: const EdgeInsets.all(12),
                        child: Image.memory(_qrCode!,
                            filterQuality: FilterQuality.none),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            '手机浏览器下载完成后会交给 Android 系统安装器；首次使用时，系统可能要求允许该浏览器“安装未知应用”。',
            style:
                TextStyle(fontSize: 12, color: Color(0xFF64748B), height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadsPanel() => _Panel(
        title: '最近传输',
        subtitle: '只记录本次运行中的完成事件。',
        child: Column(
          children: [
            for (final event in _downloads)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(child: Icon(Icons.check, size: 18)),
                title: Text(event.fileName),
                subtitle: Text('设备 ${event.remoteAddress}'),
                trailing: Text(_formatTime(event.completedAt)),
              ),
          ],
        ),
      );
}

class _LanAddress {
  const _LanAddress(this.interfaceName, this.address);

  final String interfaceName;
  final String address;

  @override
  bool operator ==(Object other) =>
      other is _LanAddress &&
      other.interfaceName == interfaceName &&
      other.address == address;

  @override
  int get hashCode => Object.hash(interfaceName, address);
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 5),
              Text(subtitle,
                  style:
                      const TextStyle(color: Color(0xFF64748B), height: 1.4)),
              const SizedBox(height: 20),
              child,
            ],
          ),
        ),
      );
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF1D4ED8), Color(0xFF0891B2)],
          ),
          borderRadius: BorderRadius.circular(22),
        ),
        child: const Row(
          children: [
            Icon(Icons.sync_alt_rounded, color: Colors.white, size: 42),
            SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('隔离网络内同步 APK',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w800)),
                  SizedBox(height: 6),
                  Text('Mac 本地直传 Android 手机，不依赖外网、云盘或内部代码仓库。',
                      style: TextStyle(color: Color(0xFFDDEAFE), fontSize: 15)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.running});

  final bool running;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: running ? const Color(0xFFDCFCE7) : const Color(0xFFE2E8F0),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          running ? '同步服务运行中' : '服务未启动',
          style: TextStyle(
            color: running ? const Color(0xFF166534) : const Color(0xFF475569),
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          border: Border.all(color: const Color(0xFFFECACA)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFB91C1C)),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      );
}

bool _isPrivateIpv4(String value) {
  final parts = value.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((part) => part == null)) return false;
  final a = parts[0]!;
  final b = parts[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

String _formatTime(DateTime value) {
  String two(int part) => part.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

String _errorMessage(Object error) => error is PlatformException
    ? error.message ?? '系统操作失败，请重试。'
    : '$error'.replaceFirst('Bad state: ', '');
