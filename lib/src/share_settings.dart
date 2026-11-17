import 'dart:convert';
import 'dart:math';

class ShareSettings {
  const ShareSettings({
    required this.token,
    this.port = 8787,
    this.autoStart = true,
    this.preferredAddress,
  });

  factory ShareSettings.fromMap(Map<Object?, Object?> values) {
    final savedToken = values['token'];
    final savedPort = values['port'];
    return ShareSettings(
      token: savedToken is String && isValidShareToken(savedToken)
          ? savedToken
          : newShareToken(),
      port: savedPort is int && savedPort >= 1024 && savedPort <= 65535
          ? savedPort
          : 8787,
      autoStart:
          values['autoStart'] is bool ? values['autoStart'] as bool : true,
      preferredAddress: values['preferredAddress'] is String
          ? values['preferredAddress'] as String
          : null,
    );
  }

  final String token;
  final int port;
  final bool autoStart;
  final String? preferredAddress;

  ShareSettings copyWith({
    String? token,
    int? port,
    bool? autoStart,
    String? preferredAddress,
  }) =>
      ShareSettings(
        token: token ?? this.token,
        port: port ?? this.port,
        autoStart: autoStart ?? this.autoStart,
        preferredAddress: preferredAddress ?? this.preferredAddress,
      );

  Map<String, Object> toMap() => {
        'token': token,
        'port': port,
        'autoStart': autoStart,
        if (preferredAddress != null) 'preferredAddress': preferredAddress!,
      };
}

bool isValidShareToken(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{24}$').hasMatch(value);

String newShareToken() {
  final random = Random.secure();
  return base64UrlEncode(List<int>.generate(18, (_) => random.nextInt(256)));
}
