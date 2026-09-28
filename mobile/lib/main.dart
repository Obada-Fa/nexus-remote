import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'session.dart';
import 'recording_control.dart';

final sessionProvider = Provider<RemoteSession>((ref) {
  final session = RemoteSession();
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
    Future.microtask(() => ref.read(sessionProvider).initialize());
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Nexus Remote'),
          actions: [
            TextButton.icon(
              onPressed: () => _showPairing(context, session),
              icon: Icon(session.connected ? Icons.laptop_mac : Icons.link_off),
              label: Text(session.status),
            ),
          ],
        ),
        body: SafeArea(
          child: switch (page) {
            0 => RemotePage(session: session, onWrite: () => setState(() => page = 1)),
            1 => WritePage(session: session),
            _ => MediaPage(session: session),
          },
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: page,
          onDestinationSelected: (value) => setState(() => page = value),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.touch_app), label: 'Remote'),
            NavigationDestination(icon: Icon(Icons.edit_note), label: 'Write'),
            NavigationDestination(icon: Icon(Icons.play_circle_outline), label: 'Media'),
          ],
        ),
      ),
    );
  }

  Future<void> _showPairing(BuildContext context, RemoteSession session) async {
    final address = TextEditingController(
      text: session.address.isEmpty ? '100.108.139.27:45679' : session.address,
    );
    final fingerprint = TextEditingController(text: session.fingerprint);
    final code = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Pair computer'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Enter the pairing code shown by the companion on your PC.'),
            const SizedBox(height: 16),
            TextField(controller: address, decoration: const InputDecoration(labelText: 'Computer address', hintText: '100.108.139.27:45679')),
            TextField(controller: code, decoration: const InputDecoration(labelText: 'Pairing code'), keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            TextField(controller: fingerprint, decoration: const InputDecoration(labelText: 'TLS SHA-256 fingerprint (optional)', hintText: 'Leave blank to auto-detect'), maxLines: 2),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                await session.pair(address: address.text, fingerprint: fingerprint.text, code: code.text);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (error) {
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(content: Text(error.toString())));
                }
              }
            },
            child: const Text('Pair'),
          ),
        ],
      ),
    );
    address.dispose();
    fingerprint.dispose();
    code.dispose();
  }
}

class RemotePage extends StatelessWidget {
  const RemotePage({super.key, required this.session, required this.onWrite});
  final RemoteSession session;
  final VoidCallback onWrite;
  void _send(Future<void> Function() command) {
    command().catchError((Object _) {});
  }
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(session.inputSupported ? 'Controlling computer'
              : session.connected ? 'Desktop input unavailable on this computer'
              : 'Connect to control the computer',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        if (session.error != null) Text(session.error!, style: const TextStyle(color: Color(0xFFFF8080))),
        const SizedBox(height: 12),
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
        ListTile(
          onTap: onWrite,
          leading: const Icon(Icons.mic, size: 32),
          title: const Text('Record a prompt'),
          subtitle: Text(session.draft.isEmpty ? 'Open Write to review text' : session.draft,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
        ),
      ]),
    );
  }
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
      pendingX += delta.dx;
      pendingY += delta.dy;
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
      child: const Center(child: Text('Touchpad', style: TextStyle(color: Color(0xFFA7B3C2)))),
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
