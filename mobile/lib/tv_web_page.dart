import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'imac_session.dart';
import 'tv_volume_control.dart';

/// Display the TV's actual phone UI. Menus, playback, catalog and styling all
/// come from that one source, including future TV updates.
class TvWebPage extends StatefulWidget {
  const TvWebPage({super.key, required this.session, required this.onExit});
  final ImacSession session;
  final VoidCallback onExit;
  @override
  State<TvWebPage> createState() => _TvWebPageState();
}

class _TvWebPageState extends State<TvWebPage> {
  bool _sameOrigin(String url, Uri origin) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        {'http', 'https'}.contains(uri.scheme) &&
        uri.origin == origin.origin;
  }

  WebViewController? _web;
  late final TextEditingController _address;
  Uri? _origin;
  String? _error;
  bool _loading = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(text: widget.session.address);
    widget.session.hardwareVolume.addListener(_syncNativeState);
    widget.session.phoneMic.addListener(_syncNativeState);
    if (_address.text.isNotEmpty) unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final origin = ImacSession.parseOrigin(_address.text);
      setState(() {
        _loading = true;
        _error = null;
        _ready = false;
        _origin = origin;
      });
      if (widget.session.address != _address.text.trim()) {
        await widget.session.setAddressAndToken(newAddress: _address.text);
      }
      if (!mounted) return;
      final web = WebViewController();
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setBackgroundColor(const Color(0xFF0B111D));
      await web.addJavaScriptChannel(
        'NexusTv',
        onMessageReceived: (message) {
          if (_origin == origin) unawaited(_message(message.message));
        },
      );
      await web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => _sameOrigin(request.url, origin)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _loading = true;
                _ready = false;
              });
            }
          },
          onPageFinished: (url) async {
            if (!mounted || !_sameOrigin(url, origin)) return;
            try {
              await web.runJavaScript(
                await rootBundle.loadString('assets/tv-native.js'),
              );
              if (!mounted) return;
              setState(() {
                _loading = false;
                _ready = true;
              });
              _syncNativeState();
              unawaited(_autoShareMic(origin));
            } catch (_) {
              if (mounted) {
                setState(() {
                  _loading = false;
                  _error = 'Could not load the TV remote. Try again.';
                });
              }
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() {
                _loading = false;
                _error =
                    'TV not reachable. Check its address and your Wi-Fi connection.';
              });
            }
          },
        ),
      );
      await web.setOnJavaScriptConfirmDialog((request) async {
        if (!mounted) return false;
        return await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                content: Text(request.message),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Continue'),
                  ),
                ],
              ),
            ) ??
            false;
      });
      if (web.platform is AndroidWebViewController) {
        await (web.platform as AndroidWebViewController).setOnShowFileSelector(
          (_) async =>
              await TvVolumeControl.channel.invokeListMethod<String>(
                'pickImage',
              ) ??
              [],
        );
      }
      if (!mounted) return;
      setState(() => _web = web);
      await web.loadRequest(origin.replace(path: '/'));
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e is FormatException
              ? e.message
              : 'Could not open the TV remote. Check the address and try again.';
        });
      }
    }
  }

  /// The phone mic becomes the TV's default input as soon as this app is connected.
  Future<void> _autoShareMic(Uri origin) async {
    final mic = widget.session.phoneMic;
    if (!mic.supported) return;
    await mic.refresh();
    try {
      final token = await TvVolumeControl.channel.invokeMethod<String>(
        'pairCookie',
        {'origin': origin.origin},
      );
      if (token != null && token.isNotEmpty && mounted && _origin == origin) {
        await mic.autoStart(origin: origin, token: token);
      }
    } catch (_) {}
  }

  Future<void> _message(String raw) async {
    if (!mounted || _origin == null) return;
    try {
      final action = (jsonDecode(raw) as Map<String, dynamic>)['action'];
      final control = widget.session.hardwareVolume;
      switch (action) {
        case 'status':
          await control.refresh();
        case 'start':
          if (!control.supported) return;
          final token = await TvVolumeControl.channel.invokeMethod<String>(
            'pairCookie',
            {'origin': _origin!.origin},
          );
          if (token == null || token.isEmpty) {
            control.error = 'Pair with the TV using its six-digit code first.';
          } else {
            await control.start(origin: _origin!, token: token);
          }
        case 'stop':
          await control.stop();
        case 'mic_start':
          final mic = widget.session.phoneMic;
          final cookie = await TvVolumeControl.channel.invokeMethod<String>(
            'pairCookie',
            {'origin': _origin!.origin},
          );
          await mic.start(origin: _origin!, token: cookie ?? '');
        case 'mic_stop':
          await widget.session.phoneMic.stop();
        case 'exit':
          widget.onExit();
          return;
        case 'address':
          await control.stop();
          await widget.session.phoneMic.stop();
          if (mounted) {
            setState(() {
              _web = null;
              _ready = false;
              _error = null;
              _loading = false;
            });
          }
          return;
        default:
          return;
      }
      _syncNativeState();
    } catch (_) {
      widget.session.hardwareVolume.error =
          'Could not change TV volume controls. Try again.';
      _syncNativeState();
    }
  }

  void _syncNativeState() {
    if (!_ready || _web == null || !mounted) return;
    final control = widget.session.hardwareVolume;
    final data = jsonEncode({
      'supported': control.supported,
      'enabled': control.enabled,
      'busy': control.busy,
      'error': control.error,
      'mic': {
        'supported': widget.session.phoneMic.supported,
        'enabled': widget.session.phoneMic.enabled,
        'busy': widget.session.phoneMic.busy,
        'error': widget.session.phoneMic.error,
      },
    });
    unawaited(
      _web!
          .runJavaScript('window.NexusNative?.update($data);')
          .catchError((_) {}),
    );
  }

  @override
  void dispose() {
    widget.session.hardwareVolume.removeListener(_syncNativeState);
    widget.session.phoneMic.removeListener(_syncNativeState);
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onExit();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B111D),
        appBar: web == null || _error != null
            ? AppBar(
                title: const Text('iMac TV'),
                leading: BackButton(onPressed: widget.onExit),
              )
            : null,
        body: SafeArea(
          child: Stack(
            children: [
              if (web != null && _error == null)
                WebViewWidget(controller: web)
              else
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Your TV remote',
                          style: TextStyle(fontSize: 24),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Enter the address shown on TV Home. Your existing remote, menus and pairing screen will open here.',
                        ),
                        const SizedBox(height: 24),
                        TextField(
                          controller: _address,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'TV address',
                            hintText: '192.168.1.20:8765',
                          ),
                          onSubmitted: (_) => _loading ? null : _open(),
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              _error!,
                              style: const TextStyle(color: Color(0xFFFF8080)),
                            ),
                          ),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _loading ? null : _open,
                          child: const Text('Open TV remote'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_loading)
                const Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
