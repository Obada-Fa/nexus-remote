import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class DesktopWindow {
  const DesktopWindow({
    required this.id,
    required this.desktop,
    required this.wmClass,
    required this.title,
    required this.appName,
    required this.isActive,
    required this.isMinimized,
    required this.isMaximized,
    this.icon,
  });

  final String id;
  final int desktop;
  final String wmClass;
  final String title;
  final String appName;
  final bool isActive;
  final bool isMinimized;
  final bool isMaximized;
  final String? icon;

  factory DesktopWindow.fromJson(Map<String, dynamic> json) {
    return DesktopWindow(
      id: json['id']?.toString() ?? '',
      desktop: (json['desktop'] as num?)?.toInt() ?? 0,
      wmClass: json['wm_class']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      appName: json['app_name']?.toString() ?? 'Window',
      isActive: json['is_active'] == true,
      isMinimized: json['is_minimized'] == true,
      isMaximized: json['is_maximized'] == true,
      icon: json['icon'] as String?,
    );
  }
}

class DesktopApp {
  const DesktopApp({
    required this.id,
    required this.name,
    this.icon,
    this.exec,
  });

  final String id;
  final String name;
  final String? icon;
  final String? exec;

  factory DesktopApp.fromJson(Map<String, dynamic> json) {
    return DesktopApp(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      icon: json['icon'] as String?,
      exec: json['exec'] as String?,
    );
  }
}

class RemoteSession extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  Database? _db;
  WebSocket? _socket;
  Timer? _heartbeat;
  Timer? _reconnect;
  Timer? _windowsTimer;
  int _reconnectAttempt = 0;
  bool _terminalAuthFailure = false;
  bool _disposed = false;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  String address = '';
  String fingerprint = '';
  String hostId = '';
  String draft = '';
  String transcriptionStatus = '';
  String? pendingRecording;
  String status = 'Not paired';
  String? error;
  bool connected = false;
  bool inputSupported = false;
  bool speechSupported = false;
  bool mediaSupported = false;
  bool windowsSupported = false;
  List<DesktopWindow> openWindows = [];
  List<DesktopApp> installedApps = [];
  String platform = '';
  int _draftRevision = 0;
  double touchpadSensitivity = 1.75;
  bool precisionMode = false;

  Future<void> setTouchpadSensitivity(double value) async {
    touchpadSensitivity = value.clamp(0.25, 3.0);
    notifyListeners();
    try {
      await _db?.insert(
        'settings',
        {'key': 'touchpad_sensitivity', 'value': touchpadSensitivity.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  Future<void> setPrecisionMode(bool enabled) async {
    precisionMode = enabled;
    notifyListeners();
    try {
      await _db?.insert(
        'settings',
        {'key': 'precision_mode', 'value': precisionMode ? '1' : '0'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  Future<void> initialize() async {
    _db = await openDatabase(
      '${await getDatabasesPath()}/nexus_remote.sqlite',
      version: 2,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE hosts (id TEXT PRIMARY KEY, address TEXT NOT NULL, fingerprint TEXT NOT NULL)');
        await db.execute('CREATE TABLE drafts (host_id TEXT PRIMARY KEY, text TEXT NOT NULL, revision INTEGER NOT NULL)');
        await db.execute('CREATE TABLE recordings (id TEXT PRIMARY KEY, host_id TEXT NOT NULL, path TEXT NOT NULL)');
        await db.execute('CREATE TABLE applied_results (id TEXT PRIMARY KEY, host_id TEXT NOT NULL)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('CREATE TABLE recordings (id TEXT PRIMARY KEY, host_id TEXT NOT NULL, path TEXT NOT NULL)');
          await db.execute('CREATE TABLE applied_results (id TEXT PRIMARY KEY, host_id TEXT NOT NULL)');
        }
      },
    );
    try {
      await _db?.execute('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      final rows = await _db?.query('settings');
      if (rows != null) {
        for (final row in rows) {
          final k = row['key'] as String;
          final v = row['value'] as String;
          if (k == 'touchpad_sensitivity') {
            final parsed = double.tryParse(v);
            if (parsed != null) touchpadSensitivity = parsed.clamp(0.25, 3.0);
          } else if (k == 'precision_mode') {
            precisionMode = v == '1' || v == 'true';
          }
        }
      }
    } catch (_) {}
    final hosts = await _db!.query('hosts', limit: 1);
    if (hosts.isNotEmpty) {
      final host = hosts.first;
      hostId = host['id'] as String;
      address = host['address'] as String;
      fingerprint = host['fingerprint'] as String;
      final rows = await _db!.query('drafts', where: 'host_id=?', whereArgs: [hostId]);
      if (rows.isNotEmpty) {
        draft = rows.first['text'] as String;
        _draftRevision = rows.first['revision'] as int;
      }
      final recordings = await _db!.query('recordings', where: 'host_id=?', whereArgs: [hostId], limit: 1);
      if (recordings.isNotEmpty) pendingRecording = recordings.first['path'] as String;
      status = 'Disconnected';
      notifyListeners();
      await connect();
    }
  }

  HttpClient _pinnedClient(String pin, {void Function(String)? onFingerprintReceived}) {
    final expected = pin.replaceAll(':', '').replaceAll(' ', '').toUpperCase();
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
    client.badCertificateCallback = (certificate, host, port) {
      final actual = sha256.convert(certificate.der).toString().toUpperCase();
      onFingerprintReceived?.call(actual);
      if (expected.isEmpty) {
        return true;
      }
      return expected.length == 64 && actual == expected;
    };
    client.connectionTimeout = const Duration(seconds: 8);
    return client;
  }

  Future<void> pair({
    required String address,
    required String fingerprint,
    required String code,
  }) async {
    final uri = _addressUri(address, '/pair');
    status = 'Pairing';
    error = null;
    notifyListeners();
    String detectedFingerprint = '';
    final client = _pinnedClient(fingerprint, onFingerprintReceived: (f) => detectedFingerprint = f);
    try {
      final request = await client.postUrl(uri);
      final bodyBytes = utf8.encode(jsonEncode({'code': code.trim(), 'device_name': 'Android phone'}));
      request.headers.contentType = ContentType.json;
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);
      final response = await request.close();
      final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw StateError(body['error']?.toString() ?? 'Pairing rejected');
      }
      final token = body['token'] as String;
      final id = body['host_id'] as String;
      final effectiveFingerprint = fingerprint.trim().isEmpty
          ? detectedFingerprint
          : fingerprint.replaceAll(':', '').replaceAll(' ', '').toUpperCase();
      await _storage.write(key: 'token:$id', value: token);
      await _db!.delete('hosts');
      await _db!.insert('hosts', {'id': id, 'address': address, 'fingerprint': effectiveFingerprint});
      hostId = id;
      this.address = address;
      this.fingerprint = effectiveFingerprint;
      _terminalAuthFailure = false;
      _reconnectAttempt = 0;
      status = 'Paired';
      notifyListeners();
      await connect();
    } catch (e) {
      status = 'Pairing failed';
      error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> updateAddress(String newAddress, {String? newFingerprint}) async {
    final cleanAddress = newAddress.trim();
    if (cleanAddress.isEmpty) {
      throw const FormatException('Enter a computer address or IP address');
    }
    _addressUri(cleanAddress, '/ws');

    address = cleanAddress;
    if (newFingerprint != null && newFingerprint.trim().isNotEmpty) {
      fingerprint = newFingerprint.replaceAll(':', '').replaceAll(' ', '').toUpperCase();
    }
    if (_db != null && hostId.isNotEmpty) {
      await _db!.update(
        'hosts',
        {
          'address': address,
          if (newFingerprint != null && newFingerprint.trim().isNotEmpty) 'fingerprint': fingerprint,
        },
        where: 'id = ?',
        whereArgs: [hostId],
      );
    }
    _terminalAuthFailure = false;
    _reconnect?.cancel();
    _reconnect = null;
    _reconnectAttempt = 0;
    _socket?.close();
    _socket = null;
    connected = false;
    error = null;
    status = hostId.isNotEmpty ? 'Connecting' : 'Pairing required';
    notifyListeners();
    if (hostId.isNotEmpty) {
      await connect();
    }
  }

  Future<void> retry() async {
    _terminalAuthFailure = false;
    _reconnect?.cancel();
    _reconnect = null;
    _reconnectAttempt = 0;
    _socket?.close();
    _socket = null;
    connected = false;
    error = null;
    status = 'Connecting';
    notifyListeners();
    await connect();
  }

  Future<void> forgetHost() async {
    _reconnect?.cancel();
    _reconnect = null;
    _reconnectAttempt = 0;
    _socket?.close();
    _socket = null;
    connected = false;
    if (hostId.isNotEmpty) {
      await _storage.delete(key: 'token:$hostId');
    }
    await _db?.delete('hosts');
    hostId = '';
    address = '';
    fingerprint = '';
    status = 'Not paired';
    error = null;
    notifyListeners();
  }

  Uri _addressUri(String address, String path) {
    var input = address.trim();
    if (input.startsWith('http://')) {
      input = 'https://${input.substring(7)}';
    } else if (input.startsWith('ws://')) {
      input = 'https://${input.substring(5)}';
    } else if (input.startsWith('wss://')) {
      input = 'https://${input.substring(6)}';
    }
    while (input.endsWith('/')) {
      input = input.substring(0, input.length - 1);
    }
    if (input.endsWith(':45678')) {
      input = '${input.substring(0, input.length - 6)}:45679';
    }
    final uri = Uri.parse(input.contains('://') ? input : 'https://$input');
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('Enter a computer address or IP address');
    }
    return uri.replace(port: uri.hasPort ? uri.port : 45679, path: path, query: '', fragment: '');
  }

  Future<void> connect() async {
    if (hostId.isEmpty || connected) return;
    final token = await _storage.read(key: 'token:$hostId');
    if (token == null) {
      status = 'Pairing required';
      notifyListeners();
      return;
    }
    status = 'Connecting';
    error = null;
    notifyListeners();
    try {
      final uri = _addressUri(address, '/ws').replace(scheme: 'wss');
      _socket = await WebSocket.connect(uri.toString(),
          headers: {'Authorization': 'Bearer $token'},
          customClient: _pinnedClient(fingerprint));
      connected = true;
      _reconnect?.cancel();
      _reconnectAttempt = 0;
      status = 'Connected';
      notifyListeners();
      _socket!.listen(_onMessage, onDone: _onDisconnect, onError: (_) => _onDisconnect(),
          cancelOnError: true);
      final host = await rpc('host.info', {});
      platform = host['platform']?.toString() ?? '';
      final capabilities = Map<String, dynamic>.from(host['capabilities'] as Map);
      inputSupported = capabilities['input'] == 'supported';
      speechSupported = capabilities['speech'] == 'supported';
      mediaSupported = capabilities['media'] == 'supported';
      windowsSupported = capabilities['windows'] == 'supported';
      notifyListeners();
      await rpc('controller.acquire', {});
      _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(rpc('controller.heartbeat', {}).then((_) {}, onError: (Object _) {}));
      });
      _windowsTimer?.cancel();
      if (windowsSupported) {
        _windowsTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
          unawaited(refreshWindows());
        });
        unawaited(refreshWindows());
        unawaited(refreshApps());
      }
    } catch (e) {
      if (e is HandshakeException || e.toString().contains('401')) {
        _terminalAuthFailure = true;
        status = e is HandshakeException ? 'Certificate changed' : 'Credential revoked';
      }
      _onDisconnect();
      error = e.toString();
      notifyListeners();
    }
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    try {
      final message = jsonDecode(data) as Map<String, dynamic>;
      final pending = _pending.remove(message['id']?.toString());
      if (pending == null) return;
      if (message['error'] is Map) {
        pending.completeError(StateError((message['error'] as Map)['message'].toString()));
      } else {
        pending.complete(Map<String, dynamic>.from(message['result'] as Map));
      }
    } catch (_) {}
  }

  void _onDisconnect() {
    final previousSocket = _socket;
    connected = false;
    inputSupported = false;
    speechSupported = false;
    mediaSupported = false;
    windowsSupported = false;
    openWindows = [];
    installedApps = [];
    _windowsTimer?.cancel();
    _windowsTimer = null;
    if (!_terminalAuthFailure) status = hostId.isEmpty ? 'Not paired' : 'Disconnected';
    _heartbeat?.cancel();
    _heartbeat = null;
    _socket = null;
    previousSocket?.close();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(StateError('Connection lost'));
    }
    _pending.clear();
    notifyListeners();
    if (!_terminalAuthFailure && hostId.isNotEmpty && !_disposed && _reconnect == null) {
      const delays = [1, 2, 4, 8, 15];
      final seconds = delays[_reconnectAttempt.clamp(0, delays.length - 1)];
      _reconnectAttempt++;
      final jitter = 0.9 + math.Random().nextDouble() * 0.2;
      _reconnect = Timer(Duration(milliseconds: (seconds * jitter * 1000).round()), () {
        _reconnect = null;
        if (!connected && !_disposed) unawaited(connect());
      });
    }
  }

  Future<Map<String, dynamic>> rpc(String method, Map<String, dynamic> params) async {
    if (!connected || _socket == null) throw StateError('Computer disconnected');
    final id = const Uuid().v4();
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket!.add(jsonEncode({'version': 1, 'id': id, 'method': method, 'params': params}));
    try {
      return await completer.future.timeout(const Duration(seconds: 8));
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> move(int dx, int dy) => rpc('input.move', {'dx': dx, 'dy': dy}).then((_) {});
  Future<void> scroll(int dx, int dy) => rpc('input.scroll', {'dx': dx, 'dy': dy}).then((_) {});
  Future<void> button(int button, bool down) =>
      rpc('input.button', {'button': button, 'down': down}).then((_) {});
  Future<void> key(String key) => rpc('input.key', {'key': key}).then((_) {});
  Future<void> click(int button) async {
    await this.button(button, true);
    await this.button(button, false);
  }

  Future<String> insert(String text) async {
    if (utf8.encode(text).length > 65536) throw StateError('Text exceeds 64 KiB');
    final id = const Uuid().v4();
    final response = await rpc('text.insert', {'operation_id': id, 'text': text});
    return response['status'] as String;
  }

  Future<String> transcribeRecording(String path, {String language = 'auto'}) async {
    if (hostId.isEmpty) throw StateError('Pair a computer first');
    final token = await _storage.read(key: 'token:$hostId');
    if (token == null) throw StateError('Pairing required');
    final file = File(path);
    final bytes = await file.readAsBytes();
    if (bytes.length > 10 * 1024 * 1024) throw StateError('Recording exceeds 10 MiB');
    final jobId = path.split(Platform.pathSeparator).last.replaceAll('.wav', '');
    await _db!.insert('recordings', {'id': jobId, 'host_id': hostId, 'path': path},
        conflictAlgorithm: ConflictAlgorithm.replace);
    pendingRecording = path;
    transcriptionStatus = 'Uploading recording';
    notifyListeners();
    final client = _pinnedClient(fingerprint);
    try {
      final request = await client.postUrl(_addressUri(address, '/transcribe'));
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('X-Job-ID', jobId);
      request.headers.set('X-Language', language);
      request.headers.set('X-Content-SHA256', sha256.convert(bytes).toString());
      request.headers.contentType = ContentType('audio', 'wav');
      request.contentLength = bytes.length;
      request.add(bytes);
      transcriptionStatus = 'Transcribing on computer';
      notifyListeners();
      final response = await request.close().timeout(const Duration(minutes: 7));
      final result = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
      if (response.statusCode != 200) throw StateError(result['error']?.toString() ?? 'Transcription failed');
      final state = result['status']?.toString();
      if (state == 'no_speech') {
        transcriptionStatus = 'No speech detected';
        notifyListeners();
        return '';
      }
      if (state != 'completed') throw StateError('Transcription did not complete');
      final text = result['text'] as String;
      await _db!.transaction((tx) async {
        final applied = await tx.query('applied_results', where: 'id=?', whereArgs: [jobId]);
        if (applied.isNotEmpty) return;
        final rows = await tx.query('drafts', where: 'host_id=?', whereArgs: [hostId]);
        final current = rows.isEmpty ? '' : rows.first['text'] as String;
        draft = current.isEmpty ? text : '$current\n$text';
        _draftRevision++;
        await tx.insert('drafts', {'host_id': hostId, 'text': draft, 'revision': _draftRevision},
            conflictAlgorithm: ConflictAlgorithm.replace);
        await tx.insert('applied_results', {'id': jobId, 'host_id': hostId});
      });
      transcriptionStatus = 'Transcription added to draft';
      notifyListeners();
      return text;
    } catch (e) {
      transcriptionStatus = 'Transcription failed. Recording is saved for retry.';
      notifyListeners();
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> rememberRecording(String path) async {
    if (hostId.isEmpty) throw StateError('Pair a computer before recording');
    final id = path.split(Platform.pathSeparator).last.replaceAll('.wav', '');
    await _db!.insert('recordings', {'id': id, 'host_id': hostId, 'path': path},
        conflictAlgorithm: ConflictAlgorithm.replace);
    pendingRecording = path;
    transcriptionStatus = 'Recording saved. Connect and retry transcription.';
    notifyListeners();
  }

  Future<void> discardPendingRecording() async {
    final path = pendingRecording;
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
    await _db!.delete('recordings', where: 'path=?', whereArgs: [path]);
    final remaining = await _db!.query('recordings', where: 'host_id=?', whereArgs: [hostId], limit: 1);
    pendingRecording = remaining.isEmpty ? null : remaining.first['path'] as String;
    transcriptionStatus = 'Saved recording discarded';
    notifyListeners();
  }

  Future<void> saveDraft(String value) async {
    if (hostId.isEmpty) return;
    draft = value;
    _draftRevision++;
    await _db!.insert('drafts', {'host_id': hostId, 'text': value, 'revision': _draftRevision},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> refreshWindows() async {
    if (!connected || !windowsSupported) return;
    try {
      final res = await rpc('window.list', {});
      if (res['windows'] is List) {
        openWindows = (res['windows'] as List)
            .map((e) => DesktopWindow.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> windowAction(String windowId, String action) async {
    try {
      await rpc('window.action', {'window_id': windowId, 'action': action});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await refreshWindows();
    } catch (_) {}
  }

  Future<void> activateWindow(String windowId) => windowAction(windowId, 'activate');
  Future<void> minimizeWindow(String windowId) => windowAction(windowId, 'minimize');
  Future<void> maximizeWindow(String windowId) => windowAction(windowId, 'maximize');
  Future<void> closeWindow(String windowId) => windowAction(windowId, 'close');
  Future<void> showDesktop() => windowAction('', 'show_desktop');

  Future<void> refreshApps() async {
    if (!connected) return;
    try {
      final res = await rpc('apps.list', {});
      if (res['apps'] is List) {
        installedApps = (res['apps'] as List)
            .map((e) => DesktopApp.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> launchApp(String appId, [String? exec]) async {
    try {
      final params = <String, dynamic>{'app_id': appId};
      if (exec != null) params['exec'] = exec;
      await rpc('apps.launch', params);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await refreshWindows();
    } catch (_) {}
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnect?.cancel();
    _heartbeat?.cancel();
    _windowsTimer?.cancel();
    _socket?.close();
    _db?.close();
    super.dispose();
  }
}
