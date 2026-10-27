import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'session.dart';
import 'imac_session.dart';
import 'tv_web_page.dart';
import 'recording_control.dart';
import 'taskbar.dart';
import 'hold_to_transcribe_button.dart';

final sessionProvider = Provider<RemoteSession>((ref) {
  final session = RemoteSession();
  ref.onDispose(session.dispose);
  return session;
});

final imacSessionProvider = Provider<ImacSession>((ref) {
  final session = ImacSession();
  ref.onDispose(session.dispose);
  return session;
});

void main() => runApp(const ProviderScope(child: NexusRemoteApp()));

class NexusRemoteApp extends StatelessWidget {
  const NexusRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus Remote',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0E1116),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF8AE3CB), brightness: Brightness.dark),
        cardColor: const Color(0xFF161C24),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});
  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  int page = 0;
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(sessionProvider).initialize();
      ref.read(imacSessionProvider).initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final imacSession = ref.watch(imacSessionProvider);
    if (page == 1) {
      return TvWebPage(session: imacSession, onExit: () => setState(() => page = 0));
    }
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Nexus Remote'),
          actions: [
            TextButton.icon(
              onPressed: () => showPairingDialog(context, session),
              icon: Icon(
                session.connected
                    ? Icons.laptop_mac
                    : (session.status == 'Connecting' ? Icons.sync : Icons.link_off),
                color: session.connected
                    ? const Color(0xFF8AE3CB)
                    : (session.status == 'Connecting' ? Colors.orangeAccent : const Color(0xFFFF8080)),
              ),
              label: Text(
                session.status,
                style: TextStyle(
                  color: session.connected
                      ? const Color(0xFF8AE3CB)
                      : (session.status == 'Connecting' ? Colors.orangeAccent : const Color(0xFFFF8080)),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.settings_ethernet),
              tooltip: 'Connection settings',
              onPressed: () => showPairingDialog(context, session),
            ),
          ],
        ),
        body: SafeArea(
          child: switch (page) {
            0 => RemotePage(session: session, onWrite: () => setState(() => page = 2)),
            2 => WritePage(session: session),
            _ => MediaPage(session: session),
          },
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (session.connected && session.windowsSupported)
              OpenAppsBar(session: session),
            NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (value) => setState(() => page = value),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.touch_app), label: 'Remote'),
                NavigationDestination(icon: Icon(Icons.tv), label: 'TV'),
                NavigationDestination(icon: Icon(Icons.edit_note), label: 'Write'),
                NavigationDestination(icon: Icon(Icons.play_circle_outline), label: 'Media'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showPairingDialog(BuildContext context, RemoteSession session) {
  return showDialog<void>(
    context: context,
    builder: (_) => PairingDialog(session: session),
  );
}

class PairingDialog extends StatefulWidget {
  const PairingDialog({super.key, required this.session});
  final RemoteSession session;

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  late final TextEditingController address;
  late final TextEditingController fingerprint;
  late final TextEditingController code;
  bool pairing = false;
  bool showRepairFields = false;
  String? error;

  @override
  void initState() {
    super.initState();
    address = TextEditingController(
      text: widget.session.address.isEmpty ? '100.108.139.27:45679' : widget.session.address,
    );
    fingerprint = TextEditingController(text: widget.session.fingerprint);
    code = TextEditingController();
    showRepairFields = widget.session.hostId.isEmpty;
  }

  @override
  void dispose() {
    address.dispose();
    fingerprint.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      pairing = true;
      error = null;
    });
    try {
      final inputCode = code.text.trim();
      final isAlreadyPaired = widget.session.hostId.isNotEmpty;
      if (inputCode.isNotEmpty || !isAlreadyPaired) {
        await widget.session.pair(
          address: address.text,
          fingerprint: fingerprint.text,
          code: code.text,
        );
      } else {
        await widget.session.updateAddress(
          address.text,
          newFingerprint: fingerprint.text.trim().isNotEmpty ? fingerprint.text : null,
        );
      }
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          pairing = false;
        });
      }
    }
  }

  Future<void> _forgetHost() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget computer?'),
        content: const Text('This will delete saved credentials. You will need a new pairing code from your PC to reconnect.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.session.forgetHost();
      setState(() {
        showRepairFields = true;
        address.text = '';
        fingerprint.text = '';
        code.text = '';
        error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPaired = widget.session.hostId.isNotEmpty;
    return AlertDialog(
      title: Text(isPaired ? 'Connection settings' : 'Pair computer'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!isPaired)
              const Text('Enter the pairing code shown by the companion on your PC.')
            else ...[
              const Text('Update your computer’s IP or host address below and tap Save & Connect.'),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: address,
              decoration: const InputDecoration(
                labelText: 'Computer address',
                hintText: '192.168.68.240:45679 or 100.108.139.27:45679',
                border: OutlineInputBorder(),
              ),
              enabled: !pairing,
            ),
            if (isPaired && !showRepairFields) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: pairing
                    ? null
                    : () {
                        setState(() {
                          showRepairFields = true;
                        });
                      },
                icon: const Icon(Icons.key, size: 16),
                label: const Text('Re-pair with new code'),
              ),
            ],
            if (showRepairFields) ...[
              const SizedBox(height: 12),
              TextField(
                controller: code,
                decoration: const InputDecoration(
                  labelText: 'Pairing code',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                enabled: !pairing,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: fingerprint,
                decoration: const InputDecoration(
                  labelText: 'TLS SHA-256 fingerprint (optional)',
                  hintText: 'Leave blank to auto-detect',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
                enabled: !pairing,
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!, style: const TextStyle(color: Color(0xFFFF8080))),
            ],
          ],
        ),
      ),
      actions: [
        if (isPaired)
          TextButton(
            onPressed: pairing ? null : _forgetHost,
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF8080)),
            child: const Text('Forget'),
          ),
        TextButton(
          onPressed: pairing ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: pairing ? null : _submit,
          child: pairing
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(!isPaired || (showRepairFields && code.text.trim().isNotEmpty) ? 'Pair' : 'Save & Connect'),
        ),
      ],
    );
  }
}

class RemotePage extends StatelessWidget {
  const RemotePage({super.key, required this.session, this.onWrite});
  final RemoteSession session;
  final VoidCallback? onWrite;
  void _send(Future<void> Function() command) {
    command().catchError((Object _) {});
  }
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: Text(
              session.inputSupported
                  ? 'Controlling computer'
                  : session.connected
                      ? 'Desktop input unavailable on this computer'
                      : 'Connect to control the computer',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ActionChip(
            avatar: Icon(
              session.precisionMode ? Icons.filter_center_focus : Icons.speed,
              size: 16,
            ),
            label: Text(
              '${((session.touchpadSensitivity * 10) % 1 == 0 ? session.touchpadSensitivity.toStringAsFixed(1) : session.touchpadSensitivity.toStringAsFixed(2))}x'
              '${session.precisionMode ? " (slow)" : ""}',
            ),
            onPressed: () => _showTouchpadSettings(context, session),
          ),
        ]),
        if (!session.connected) ...[
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: session.error != null ? const Color(0xFF241519) : const Color(0xFF161C24),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: session.error != null ? const Color(0xFF6B2A35) : const Color(0xFF2D3948),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      session.error != null
                          ? Icons.error_outline
                          : (session.status == 'Connecting' ? Icons.sync : Icons.wifi_off),
                      size: 20,
                      color: session.error != null
                          ? const Color(0xFFFF8080)
                          : (session.status == 'Connecting' ? Colors.orangeAccent : const Color(0xFFA7B3C2)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        session.status == 'Connecting'
                            ? 'Connecting to computer...'
                            : (session.error != null ? 'Connection error' : 'Disconnected'),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: session.error != null
                              ? const Color(0xFFFF8080)
                              : (session.status == 'Connecting' ? Colors.orangeAccent : Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
                if (session.address.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Target: ${session.address}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFFA7B3C2)),
                  ),
                ],
                if (session.error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    session.error!,
                    style: const TextStyle(fontSize: 12, color: Color(0xFFFFB4B4)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => showPairingDialog(context, session),
                      icon: const Icon(Icons.edit, size: 16),
                      label: const Text('Change IP / Host'),
                    ),
                    if (session.hostId.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => session.retry(),
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Retry'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        Expanded(child: IgnorePointer(ignoring: !session.inputSupported,
          child: Touchpad(session: session))),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: SizedBox(height: 56, child: FilledButton.tonal(
            onPressed: session.inputSupported ? () => _send(() => session.click(1)) : null,
            child: const Text('Left click'),
          ))),
          const SizedBox(width: 8),
          Expanded(child: SizedBox(height: 56, child: FilledButton.tonal(
            onPressed: session.inputSupported ? () => _send(() => session.click(3)) : null,
            child: const Text('Right click'),
          ))),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 4, children: [
          for (final key in ['Escape','Tab','Enter','Copy','Paste'])
            OutlinedButton(onPressed: session.inputSupported ? () => _send(() => session.key(key)) : null,
              child: Text(key)),
        ]),
        const SizedBox(height: 8),
        HoldToTranscribeButton(session: session),
      ]),
    );
  }
}

void _showTouchpadSettings(BuildContext context, RemoteSession session) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF161C24),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Touchpad Speed', style: Theme.of(context).textTheme.titleLarge),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Sensitivity: ${session.touchpadSensitivity.toStringAsFixed(2)}x',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Slider(
                  value: session.touchpadSensitivity.clamp(0.25, 3.0),
                  min: 0.25,
                  max: 3.0,
                  divisions: 11,
                  label: '${session.touchpadSensitivity.toStringAsFixed(2)}x',
                  onChanged: (val) {
                    session.setTouchpadSensitivity(val);
                    setModalState(() {});
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('1.0x (Slow)'),
                      selected: (session.touchpadSensitivity - 1.0).abs() < 0.05,
                      onSelected: (_) {
                        session.setTouchpadSensitivity(1.0);
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: const Text('1.75x (Default)'),
                      selected: (session.touchpadSensitivity - 1.75).abs() < 0.05,
                      onSelected: (_) {
                        session.setTouchpadSensitivity(1.75);
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: const Text('2.5x (Fast)'),
                      selected: (session.touchpadSensitivity - 2.5).abs() < 0.05,
                      onSelected: (_) {
                        session.setTouchpadSensitivity(2.5);
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
                const Divider(height: 32),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Precision Mode'),
                  subtitle: const Text('Applies 0.35x multiplier for fine cursor positioning'),
                  value: session.precisionMode,
                  onChanged: (val) {
                    session.setPrecisionMode(val);
                    setModalState(() {});
                  },
                ),
              ],
            ),
          ));
        },
      );
    },
  );
}

class Touchpad extends StatefulWidget {
  const Touchpad({super.key, required this.session});
  final RemoteSession session;
  @override
  State<Touchpad> createState() => _TouchpadState();
}
class _TouchpadState extends State<Touchpad> {
  final Map<int, Offset> pointers = {};
  final Map<int, Offset> starts = {};
  final Map<int, DateTime> startedAt = {};
  Timer? longPress;
  Timer? frame;
  double pendingX = 0;
  double pendingY = 0;
  bool dragging = false;
  bool moved = false;
  bool multiTouch = false;
  bool multiMoved = false;
  DateTime? multiStarted;
  double scrollX = 0;
  double scrollY = 0;
  @override
  void dispose() {
    longPress?.cancel();
    frame?.cancel();
    if (dragging) widget.session.button(1, false).catchError((Object _) {});
    super.dispose();
  }
  void _flush() {
    final dx = pendingX.truncate();
    final dy = pendingY.truncate();
    pendingX -= dx;
    pendingY -= dy;
    if (dx != 0 || dy != 0) widget.session.move(dx, dy).catchError((Object _) {});
  }
  void _down(PointerDownEvent event) {
    pointers[event.pointer] = event.localPosition;
    starts[event.pointer] = event.localPosition;
    startedAt[event.pointer] = DateTime.now();
    if (pointers.length == 1) moved = false;
    if (pointers.length == 1) {
      longPress = Timer(const Duration(milliseconds: 450), () {
        if (pointers.length == 1 && !moved) {
          dragging = true;
          widget.session.button(1, true).catchError((Object _) {});
        }
      });
    } else {
      longPress?.cancel();
      multiTouch = true;
      multiMoved = false;
      multiStarted = DateTime.now();
    }
  }
  void _move(PointerMoveEvent event) {
    final old = pointers[event.pointer];
    if (old == null) return;
    final delta = event.localPosition - old;
    pointers[event.pointer] = event.localPosition;
    if ((event.localPosition - (starts[event.pointer] ?? old)).distance > 8) {
      moved = true;
      longPress?.cancel();
    }
    if (pointers.length == 1) {
      final multiplier = widget.session.touchpadSensitivity * (widget.session.precisionMode ? 0.35 : 1.0);
      pendingX += delta.dx * multiplier;
      pendingY += delta.dy * multiplier;
      frame ??= Timer(const Duration(milliseconds: 16), () {
        frame = null;
        _flush();
      });
    } else if (pointers.length == 2 && delta.distance > 2) {
      if (delta.distance > 8) multiMoved = true;
      scrollX -= delta.dx / 18;
      scrollY -= delta.dy / 18;
      final sx = scrollX.truncate();
      final sy = scrollY.truncate();
      scrollX -= sx;
      scrollY -= sy;
      if (sx != 0 || sy != 0) {
        multiMoved = true;
        widget.session.scroll(sx, sy).catchError((Object _) {});
      }
    }
  }
  void _up(PointerEvent event) {
    final start = starts.remove(event.pointer);
    final began = startedAt.remove(event.pointer);
    pointers.remove(event.pointer);
    longPress?.cancel();
    _flush();
    if (dragging) {
      dragging = false;
      widget.session.button(1, false).catchError((Object _) {});
    } else if (pointers.isEmpty && multiTouch) {
      if (!multiMoved && multiStarted != null &&
          DateTime.now().difference(multiStarted!).inMilliseconds <= 250) {
        widget.session.click(3).catchError((Object _) {});
      }
    } else if (!multiTouch && start != null && began != null &&
        (event.localPosition - start).distance <= 8 &&
        DateTime.now().difference(began).inMilliseconds <= 250) {
      widget.session.click(1).catchError((Object _) {});
    }
    if (pointers.isEmpty) {
      moved = false;
      multiTouch = false;
      multiMoved = false;
      multiStarted = null;
    }
  }
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: const Color(0xFF161C24), border: Border.all(color: const Color(0xFF2D3948)),
      borderRadius: BorderRadius.circular(18)),
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: Center(
        child: Text(
          widget.session.precisionMode ? 'Touchpad (Precision Mode)' : 'Touchpad',
          style: const TextStyle(color: Color(0xFFA7B3C2)),
        ),
      ),
    ),
  );
}

class WritePage extends StatefulWidget {
  const WritePage({super.key, required this.session});
  final RemoteSession session;
  @override
  State<WritePage> createState() => _WritePageState();
}
class _WritePageState extends State<WritePage> {
  late final TextEditingController editor;
  Timer? save;
  String? receipt;
  @override
  void initState() {
    super.initState();
    editor = TextEditingController(text: widget.session.draft);
    editor.addListener(() {
      save?.cancel();
      save = Timer(const Duration(milliseconds: 300), () => widget.session.saveDraft(editor.text));
    });
  }
  @override
  void dispose() {
    save?.cancel();
    widget.session.saveDraft(editor.text);
    editor.dispose();
    super.dispose();
  }
  Future<void> _insert() async {
    try {
      final result = await widget.session.insert(editor.text);
      if (mounted) {
        setState(() => receipt = result == 'paste_dispatched'
            ? 'Paste dispatched. Check the computer before pressing Enter.'
            : 'Delivery status: $result');
      }
    } catch (error) {
      if (mounted) {
        setState(() => receipt = error.toString());
      }
    }
  }
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Write on your phone', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      const Text('Review the text before inserting it into the focused computer application.'),
      const SizedBox(height: 12),
      Expanded(child: TextField(
        controller: editor, expands: true, maxLines: null, minLines: null,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(hintText: 'Type or use your keyboard’s voice input…',
          border: OutlineInputBorder()),
      )),
      if (receipt != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(receipt!)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: widget.session.inputSupported ? _insert : null,
          icon: const Icon(Icons.send_to_mobile), label: const Text('Insert into PC'),
        ),
        OutlinedButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: editor.text)),
          child: const Text('Copy on phone'),
        ),
        OutlinedButton(
          onPressed: widget.session.inputSupported ? () => widget.session.key('Enter') : null,
          child: const Text('Enter'),
        ),
      ]),
      const SizedBox(height: 8),
      RecordingControl(
        session: widget.session,
        beforeUpload: () => widget.session.saveDraft(editor.text),
        onTranscript: () {
          editor.text = widget.session.draft;
          editor.selection = TextSelection.collapsed(offset: editor.text.length);
        },
      ),
    ]),
  );
}

class MediaPage extends StatefulWidget {
  const MediaPage({super.key, required this.session});
  final RemoteSession session;
  @override
  State<MediaPage> createState() => _MediaPageState();
}
class _MediaPageState extends State<MediaPage> {
  List<Map<String, dynamic>> players = [];
  String? selectedId;
  int volume = 0;
  bool muted = false;
  bool loading = false;
  String? error;
  double? seekValue;
  late bool wasConnected;
  @override
  void initState() {
    super.initState();
    wasConnected = widget.session.connected;
    widget.session.addListener(_connectionChanged);
    if (wasConnected) Future.microtask(_refresh);
  }
  void _connectionChanged() {
    if (widget.session.connected && !wasConnected) {
      wasConnected = true;
      _refresh();
    } else if (!widget.session.connected) {
      wasConnected = false;
    }
  }
  @override
  void dispose() {
    widget.session.removeListener(_connectionChanged);
    super.dispose();
  }
  Future<void> _refresh() async {
    if (!widget.session.connected || loading) return;
    setState(() { loading = true; error = null; });
    try {
      final media = await widget.session.rpc('media.list', {});
      final volumeState = await widget.session.rpc('volume.state', {});
      final found = (media['players'] as List).map((item) => Map<String, dynamic>.from(item as Map)).toList();
      if (selectedId == null && found.isNotEmpty) {
        final playing = found.where((player) => player['status'] == 'Playing');
        selectedId = (playing.isNotEmpty ? playing.first : found.first)['id'] as String;
      }
      if (mounted) {
        setState(() {
          players = found;
          volume = (volumeState['percent'] as num).round().clamp(0, 100);
          muted = volumeState['muted'] as bool;
        });
      }
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }
  Future<void> _action(String action) async {
    if (selectedId == null) return;
    try {
      await widget.session.rpc('media.action', {'player_id': selectedId, 'action': action});
      await _refresh();
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    }
  }
  Future<void> _setVolume(int value) async {
    try {
      final state = await widget.session.rpc('volume.set', {'percent': value});
      if (mounted) setState(() => volume = (state['percent'] as num).round());
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    }
  }
  Future<void> _toggleMute() async {
    try {
      final state = await widget.session.rpc('volume.mute', {'muted': !muted});
      if (mounted) setState(() => muted = state['muted'] as bool);
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    }
  }
  Future<void> _seek(double value) async {
    if (selectedId == null) return;
    try {
      await widget.session.rpc('media.seek', {'player_id': selectedId, 'seconds': value.round()});
      await _refresh();
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    }
  }
  @override
  Widget build(BuildContext context) {
    final available = widget.session.connected;
    final selected = players.where((player) => player['id'] == selectedId).firstOrNull;
    final missing = selectedId != null && selected == null;
    final duration = (selected?['duration_seconds'] as num?)?.toDouble();
    final position = (selected?['position_seconds'] as num?)?.toDouble() ?? 0;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(child: Text('Media', style: Theme.of(context).textTheme.titleLarge)),
        IconButton(onPressed: available && !loading ? _refresh : null,
          icon: const Icon(Icons.refresh), tooltip: 'Refresh players'),
      ]),
      if (!available) const Text('Connect to a computer to control playback.'),
      if (error != null) Text(error!, style: const TextStyle(color: Color(0xFFFF8080))),
      if (missing) const Text('Selected player disappeared. Choose another player to continue.'),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        key: ValueKey(players.map((player) => player['id']).join('|')),
        initialValue: selected?['id'] as String?,
        decoration: const InputDecoration(labelText: 'Media player', border: OutlineInputBorder()),
        items: players.map((player) => DropdownMenuItem<String>(
          value: player['id'] as String, child: Text(player['id'] as String),
        )).toList(),
        onChanged: available ? (value) => setState(() => selectedId = value) : null,
      ),
      const SizedBox(height: 16),
      Text(selected?['title']?.toString().isNotEmpty == true ? selected!['title'] as String : 'No track',
          style: Theme.of(context).textTheme.titleMedium),
      Text(selected?['status']?.toString() ?? 'No player selected'),
      const SizedBox(height: 16),
      Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
        IconButton.filledTonal(onPressed: selected == null ? null : () => _action('previous'),
          icon: const Icon(Icons.skip_previous), tooltip: 'Previous'),
        IconButton.filledTonal(onPressed: selected == null ? null : () => _action('backward'),
          icon: const Icon(Icons.replay_10), tooltip: 'Back ten seconds'),
        IconButton.filled(onPressed: selected == null ? null : () => _action('play_pause'),
          icon: Icon(selected?['status'] == 'Playing' ? Icons.pause : Icons.play_arrow), tooltip: 'Play or pause'),
        IconButton.filledTonal(onPressed: selected == null ? null : () => _action('forward'),
          icon: const Icon(Icons.forward_10), tooltip: 'Forward ten seconds'),
        IconButton.filledTonal(onPressed: selected == null ? null : () => _action('next'),
          icon: const Icon(Icons.skip_next), tooltip: 'Next'),
      ]),
      if (selected != null && duration != null && duration > 0) ...[
        const SizedBox(height: 12),
        Slider(value: (seekValue ?? position).clamp(0, duration), max: duration,
          onChanged: (value) => setState(() => seekValue = value),
          onChangeEnd: (value) { setState(() => seekValue = null); _seek(value); }),
        Text('${position.round()} / ${duration.round()} seconds', textAlign: TextAlign.center),
      ],
      const SizedBox(height: 24),
      const Divider(),
      Text('System volume', style: Theme.of(context).textTheme.titleMedium),
      Row(children: [
        IconButton(onPressed: available ? _toggleMute : null,
          icon: Icon(muted ? Icons.volume_off : Icons.volume_up), tooltip: muted ? 'Unmute' : 'Mute'),
        Expanded(child: Slider(value: volume.toDouble().clamp(0, 100), max: 100,
          onChanged: available ? (value) => setState(() => volume = value.round()) : null,
          onChangeEnd: available ? (value) => _setVolume(value.round()) : null)),
        Text('$volume%'),
      ]),
    ]);
  }
}
