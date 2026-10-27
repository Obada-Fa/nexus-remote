import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'tv_volume_control.dart';

class ImacPlaybackInfo {
  const ImacPlaybackInfo({
    this.active = false,
    this.title = '',
    this.position = 0.0,
    this.duration = 0.0,
    this.paused = false,
  });

  final bool active;
  final String title;
  final double position;
  final double duration;
  final bool paused;

  factory ImacPlaybackInfo.fromJson(Map<String, dynamic> json) {
    return ImacPlaybackInfo(
      active: json['active'] == true,
      title: json['title']?.toString() ?? '',
      position: (json['position'] as num?)?.toDouble() ?? 0.0,
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      paused: json['paused'] == true,
    );
  }
}

class ImacSession extends ChangeNotifier {
  final hardwareVolume = TvVolumeControl();
  Database? _db;
  Timer? _pollTimer;
  bool _disposed = false;

  String address = '';
  String token = '';
  String legacyKey = '';
  String status = 'Not configured';
  String? error;
  bool connected = false;

  // TV state
  String app = 'home';
  String phase = 'ready';
  bool gui = false;
  int? volume;
  bool muted = false;
  double? cpuTemperature;
  double? gpuTemperature;
  bool thermalWarning = false;
  ImacPlaybackInfo playback = const ImacPlaybackInfo();
  double? timerDeadline;
  int? brightnessLevel;
  bool brightnessAvailable = false;
  bool screenOff = false;
  bool oldLinkActive = false;
  List<Map<String, dynamic>> subtitles = const [];

  HttpClient _client() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);
    return client;
  }

  static Uri parseOrigin(String address) {
    final input = address.trim();
    final uri = Uri.parse(input.contains('://') ? input : 'http://$input');
    if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('Enter the TV address, for example 192.168.1.20:8765');
    }
    return Uri(scheme: uri.scheme, host: uri.host,
        port: uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 8765));
  }

  Uri get origin => parseOrigin(address);

  Uri _uri(String path, [Map<String, String>? queryParams]) {

    final q = Map<String, String>.from(queryParams ?? {});
    if (legacyKey.isNotEmpty && !q.containsKey('k')) {
      q['k'] = legacyKey;
    }

    return origin.replace(
      path: path,
      queryParameters: q.isEmpty ? null : q,
    );
  }

  void _applyHeaders(HttpHeaders headers) {
    if (token.isNotEmpty) {
      headers.set(HttpHeaders.cookieHeader, 'imactv=$token; tvremote=$token');
    } else if (legacyKey.isNotEmpty) {
      headers.set(HttpHeaders.cookieHeader, 'tvremote=$legacyKey');
    }
  }

  Future<void> initialize() async {
    await hardwareVolume.initialize();
    try {
      _db = await openDatabase('${await getDatabasesPath()}/nexus_remote.sqlite');
      await _db?.execute(
        'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      final rows = await _db?.query('settings');
      if (rows != null) {
        for (final row in rows) {
          final k = row['key'] as String;
          final v = row['value'] as String;
          if (k == 'imac_address') {
            address = v;
          } else if (k == 'imac_token') {
            token = v;
          } else if (k == 'imac_legacy_key') {
            legacyKey = v;
          }
        }
      }
    } catch (_) {}

    if (address.isNotEmpty) {
      status = 'Connecting';
      notifyListeners();
      await pollState();
      _startPolling();
    } else {
      status = 'Not configured';
      notifyListeners();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_disposed && address.isNotEmpty) {
        unawaited(pollState());
      }
    });
  }

  Future<void> setAddressAndToken({
    required String newAddress,
    String? newToken,
    String? newLegacyKey,
  }) async {
    final clean = newAddress.trim();
    if (clean.isEmpty) {
      throw const FormatException('Enter iMac IP address (e.g. 192.168.68.xxx:8765)');
    }
    final nextOrigin = parseOrigin(clean);
    final changedHost = address.isNotEmpty && origin != nextOrigin;
    if (changedHost || newToken != null || newLegacyKey != null) {
      await hardwareVolume.stop();
    }
    address = clean;
    // A pairing token belongs to one TV. Never send it to a newly entered host.
    if (changedHost) {
      token = '';
      legacyKey = '';
    }
    if (newToken != null) token = newToken.trim();
    if (newLegacyKey != null) legacyKey = newLegacyKey.trim();

    try {
      await _db?.insert(
        'settings',
        {'key': 'imac_address', 'value': address},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (newToken != null || changedHost) {
        await _db?.insert(
          'settings',
          {'key': 'imac_token', 'value': token},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      if (newLegacyKey != null || changedHost) {
        await _db?.insert(
          'settings',
          {'key': 'imac_legacy_key', 'value': legacyKey},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    } catch (_) {}

    error = null;
    status = 'Connecting';
    notifyListeners();
    await pollState();
    _startPolling();
  }

  Future<void> pair(String code) async {
    final cleanCode = code.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(cleanCode)) {
      throw const FormatException('Enter the 6-digit code shown on iMac TV Home');
    }
    final client = _client();
    try {
      final uri = _uri('/api/pair');
      final request = await client.postUrl(uri);
      final bodyBytes = utf8.encode(jsonEncode({'code': cleanCode}));
      request.headers.contentType = ContentType.json;
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);
      final response = await request.close().timeout(const Duration(seconds: 5));
      final raw = await utf8.decoder.bind(response).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;

      if (response.statusCode != 200) {
        throw StateError(body['error']?.toString() ?? 'Pairing rejected');
      }

      String receivedToken = body['token'] as String? ?? '';
      if (receivedToken.isEmpty) {
        for (final cookie in response.cookies) {
          if (cookie.name == 'imactv' || cookie.name == 'tvremote') {
            receivedToken = cookie.value;
            break;
          }
        }
      }

      if (receivedToken.isNotEmpty) {
        await setAddressAndToken(newAddress: address, newToken: receivedToken);
      } else {
        throw StateError('TV did not return a pairing token');
      }
      connected = true;
      status = 'Connected';
      error = null;
      notifyListeners();
    } finally {
      client.close();
    }
  }

  Future<void> pollState() async {
    if (address.isEmpty) return;
    final client = _client();
    try {
      // 1. Try modern tvapp JSON endpoint
      final uri = _uri('/api/state');
      final request = await client.getUrl(uri);
      _applyHeaders(request.headers);
      final response = await request.close().timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final raw = await utf8.decoder.bind(response).join();
        final data = jsonDecode(raw) as Map<String, dynamic>;
        app = data['app']?.toString() ?? 'home';
        phase = data['phase']?.toString() ?? 'ready';
        gui = data['gui'] == true;
        volume = (data['volume'] as num?)?.toInt();
        muted = data['muted'] == true;
        cpuTemperature = (data['temperature'] as num?)?.toDouble();
        gpuTemperature = (data['gpu_temperature'] as num?)?.toDouble();
        thermalWarning = data['thermal_warning'] == true;
        oldLinkActive = data['old_link_active'] == true;
        screenOff = data['screen_off'] == true;

        if (data['brightness'] is Map) {
          final b = data['brightness'] as Map;
          brightnessLevel = (b['level'] as num?)?.toInt();
          brightnessAvailable = b['available'] == true;
        }

        if (data['playback'] is Map) {
          final pMap = Map<String, dynamic>.from(data['playback'] as Map);
          playback = ImacPlaybackInfo.fromJson(pMap);
          if (pMap['subtitles'] is List) {
            subtitles = (pMap['subtitles'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          } else {
            subtitles = const [];
          }
        } else {
          subtitles = const [];
        }

        if (data['timer'] is Map) {
          final t = data['timer'] as Map;
          timerDeadline = t['active'] == true ? (t['deadline'] as num?)?.toDouble() : null;
        } else {
          timerDeadline = null;
        }

        connected = true;
        status = 'Connected';
        error = null;
        notifyListeners();
        return;
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        connected = false;
        status = 'Pairing required';
        error = 'Authentication required. Pair using 6-digit code or key.';
        notifyListeners();
        return;
      }

      // 2. Fallback to legacy remote.py /state
      if (response.statusCode == 404) {
        final legacyUri = _uri('/state');
        final legReq = await client.getUrl(legacyUri);
        _applyHeaders(legReq.headers);
        final legRes = await legReq.close().timeout(const Duration(seconds: 3));
        if (legRes.statusCode == 200) {
          final stateText = (await utf8.decoder.bind(legRes).join()).trim();
          connected = true;
          status = 'Connected';
          error = null;
          app = stateText.toLowerCase().contains('stremio')
              ? 'stremio'
              : stateText.toLowerCase().contains('youtube')
                  ? 'youtube'
                  : stateText.toLowerCase().contains('vlc')
                      ? 'vlc'
                      : 'home';
          playback = ImacPlaybackInfo(
            active: stateText.contains('PLAYING'),
            title: stateText,
          );
          notifyListeners();
          return;
        }
      }

      connected = false;
      status = 'Disconnected';
      error = 'iMac returned status ${response.statusCode}';
      notifyListeners();
    } catch (e) {
      connected = false;
      status = 'Disconnected';
      error = e.toString();
      notifyListeners();
    } finally {
      client.close();
    }
  }

  Future<void> sendCommand(String action, [Map<String, dynamic>? params]) async {
    if (address.isEmpty) {
      throw StateError('Set iMac address in settings first');
    }
    final client = _client();
    try {
      // 1. Try modern /api/commands
      final uri = _uri('/api/commands');
      final request = await client.postUrl(uri);
      _applyHeaders(request.headers);
      final bodyBytes = utf8.encode(jsonEncode({'action': action, 'params': params ?? {}}));
      request.headers.contentType = ContentType.json;
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);
      final response = await request.close().timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        await response.drain<void>();
        unawaited(pollState());
        return;
      }

      // 2. Fallback to legacy remote.py /cmd/<action>
      if (response.statusCode == 404) {
        final query = <String, String>{};
        if (params != null) {
          for (final entry in params.entries) {
            query[entry.key] = entry.value.toString();
          }
        }
        final legacyUri = _uri('/cmd/$action', query);
        final legReq = await client.postUrl(legacyUri);
        _applyHeaders(legReq.headers);
        legReq.contentLength = 0;
        final legRes = await legReq.close().timeout(const Duration(seconds: 4));
        if (legRes.statusCode == 200 || legRes.statusCode == 204) {
          unawaited(pollState());
          return;
        }
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        connected = false;
        status = 'Pairing required';
        error = 'Authentication failed. Check pairing code on iMac TV.';
        notifyListeners();
        throw StateError(error!);
      }
      throw StateError('TV command failed (${response.statusCode})');
    } catch (e) {
      error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      client.close();
    }
  }

  // Quick action shortcuts
  Future<void> dpad(String dir) => sendCommand(dir);
  Future<void> selectApp(String targetApp) async {
    app = targetApp;
    phase = 'opening';
    notifyListeners();
    await sendCommand('select', {'app': targetApp});
  }
  Future<void> playPause() => sendCommand('play');
  Future<void> back() => sendCommand('back');
  Future<void> home() => sendCommand('home');
  Future<void> escape() => sendCommand('esc');
  Future<void> fullscreen() => sendCommand('fullscreen');
  Future<void> rewind() => sendCommand('left');
  Future<void> fastForward() => sendCommand('right');
  Future<void> seek(double seconds) => sendCommand('seek', {'seconds': seconds});
  Future<void> volumeUp() async {
    if (volume != null) {
      volume = (volume! + 5).clamp(0, 100);
      notifyListeners();
    }
    await sendCommand('volume', {'direction': 1});
  }
  Future<void> volumeDown() async {
    if (volume != null) {
      volume = (volume! - 5).clamp(0, 100);
      notifyListeners();
    }
    await sendCommand('volume', {'direction': -1});
  }
  Future<void> toggleMute() async {
    muted = !muted;
    notifyListeners();
    await sendCommand('mute');
  }
  Future<void> movePointer(int dx, int dy) => sendCommand('move', {'dx': dx, 'dy': dy});
  Future<void> clickPointer(int button) =>
      sendCommand(button == 3 ? 'rightclick' : 'click');
  Future<void> typeText(String text) => sendCommand('type', {'text': text});
  Future<void> setTimer(int? minutes) async {
    if (minutes != null) {
      timerDeadline = (DateTime.now().millisecondsSinceEpoch / 1000.0) + (minutes * 60);
    } else {
      timerDeadline = null;
    }
    notifyListeners();
    await sendCommand('timer', {'minutes': minutes});
  }
  Future<void> powerOff() => sendCommand('poweroff', {'confirm': true});
  Future<void> recover() => sendCommand('recover');
  Future<void> setBrightness(int level) => sendCommand('brightness', {'level': level});
  Future<void> toggleScreen() => sendCommand('screen', {'on': null});
  Future<void> selectSubtitle(dynamic id) => sendCommand('subtitle', {'id': id});
  Future<void> restartApp() => sendCommand('restart_app');
  Future<void> restartSession() => sendCommand('restart_session', {'confirm': true});
  Future<void> revokeOldLink() => sendCommand('revoke', {'mode': 'old_link'});

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    hardwareVolume.dispose();
    super.dispose();
  }
}
