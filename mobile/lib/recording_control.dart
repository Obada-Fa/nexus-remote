import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import 'session.dart';
import 'audio.dart';

class RecordingControl extends StatefulWidget {
  const RecordingControl({super.key, required this.session, required this.onTranscript, required this.beforeUpload});
  final RemoteSession session;
  final VoidCallback onTranscript;
  final Future<void> Function() beforeUpload;
  @override
  State<RecordingControl> createState() => _RecordingControlState();
}

class _RecordingControlState extends State<RecordingControl> with WidgetsBindingObserver {
  final AudioRecorder recorder = AudioRecorder();
  Timer? timer;
  DateTime? started;
  bool recording = false;
  bool processing = false;
  bool holdMode = false;
  bool cancelling = false;
  String language = 'auto';
  String? message;
  int seconds = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (recording && state != AppLifecycleState.resumed) {
      unawaited(_stop(upload: false));
    }
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    if (recording) unawaited(recorder.stop());
    unawaited(recorder.dispose());
    super.dispose();
  }
  Future<void> _start() async {
    if (recording || processing || widget.session.hostId.isEmpty) return;
    try {
      if (!await recorder.hasPermission()) {
        setState(() => message = 'Microphone permission denied. Other controls remain available.');
        return;
      }
      final directory = await getApplicationDocumentsDirectory();
      var retainedBytes = 0;
      await for (final entry in directory.list()) {
        if (entry is File && entry.path.endsWith('.wav')) {
          retainedBytes += await entry.length();
        }
      }
      if (retainedBytes >= 100 * 1024 * 1024) {
        throw StateError('Recording storage is full. Finish or discard saved recordings.');
      }
      final path = '${directory.path}/${const Uuid().v4()}.wav';
      await recorder.start(const RecordConfig(
        encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1,
        audioInterruption: AudioInterruptionMode.pause,
      ), path: path);
      started = DateTime.now();
      setState(() { recording = true; seconds = 0; message = null; });
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => seconds = DateTime.now().difference(started!).inSeconds);
        if (seconds >= 300) unawaited(_stop(upload: true));
      });
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    }
  }
  Future<void> _stop({required bool upload}) async {
    if (!recording) return;
    timer?.cancel();
    setState(() { recording = false; processing = true; });
    try {
      final path = await recorder.stop();
      if (path == null) throw StateError('Recording could not be saved');
      if (cancelling) {
        await File(path).delete();
        cancelling = false;
        if (mounted) setState(() => message = 'Recording cancelled');
      } else if (upload && widget.session.connected) {
        await AudioNormalizer.normalize(File(path));
        await widget.beforeUpload();
        await widget.session.transcribeRecording(path, language: language);
        widget.onTranscript();
        if (mounted) setState(() => message = widget.session.transcriptionStatus);
      } else {
        await AudioNormalizer.normalize(File(path));
        await widget.session.rememberRecording(path);
        if (mounted) setState(() => message = widget.session.transcriptionStatus);
      }
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }
  Future<void> _retry() async {
    final path = widget.session.pendingRecording;
    if (path == null || processing) return;
    setState(() { processing = true; message = null; });
    try {
      await widget.beforeUpload();
      await widget.session.transcribeRecording(path, language: language);
      widget.onTranscript();
      if (mounted) setState(() => message = widget.session.transcriptionStatus);
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      SegmentedButton<bool>(
        segments: const [ButtonSegment(value: false, label: Text('Tap')),
          ButtonSegment(value: true, label: Text('Hold'))],
        selected: {holdMode},
        onSelectionChanged: recording || processing ? null : (value) => setState(() => holdMode = value.first),
      ),
      const SizedBox(width: 12),
      DropdownButton<String>(
        value: language,
        items: const [
          DropdownMenuItem(value: 'auto', child: Text('Automatic')),
          DropdownMenuItem(value: 'en', child: Text('English')),
          DropdownMenuItem(value: 'nl', child: Text('Dutch')),
        ],
        onChanged: recording || processing ? null : (value) => setState(() => language = value ?? 'auto'),
      ),
    ]),
    const SizedBox(height: 8),
    Row(children: [
      if (holdMode)
        GestureDetector(
          onLongPressStart: (_) => unawaited(_start()),
          onLongPressEnd: (_) => unawaited(_stop(upload: true)),
          onLongPressMoveUpdate: (details) {
            if (details.offsetFromOrigin.distance > 80 && recording) {
              cancelling = true;
              unawaited(_stop(upload: false));
            }
          },
          child: const SizedBox(width: 80, height: 80,
            child: Card(child: Icon(Icons.mic, size: 36))),
        )
      else
        SizedBox(width: 80, height: 80, child: FilledButton(
          onPressed: processing ? null : () => recording ? _stop(upload: true) : _start(),
          child: Icon(recording ? Icons.stop : Icons.mic, size: 32),
        )),
      const SizedBox(width: 12),
      Expanded(child: Text(recording ? 'Recording ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}'
          : processing ? 'Processing recording…' : 'Record on phone, transcribe on computer')),
      if (recording) TextButton(onPressed: () {
        cancelling = true;
        unawaited(_stop(upload: false));
      }, child: const Text('Cancel')),
    ]),
    if (widget.session.pendingRecording != null && !recording)
      Wrap(spacing: 8, children: [
        TextButton.icon(
          onPressed: processing || !widget.session.connected ? null : _retry,
          icon: const Icon(Icons.refresh), label: const Text('Retry saved recording'),
        ),
        TextButton(
          onPressed: processing ? null : () async {
            final discard = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
              title: const Text('Discard saved audio?'),
              content: const Text('The current draft text will be kept.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep')),
                FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Discard')),
              ],
            ));
            if (discard == true) await widget.session.discardPendingRecording();
          },
          child: const Text('Discard audio'),
        ),
      ]),
    if (widget.session.connected && !widget.session.speechSupported)
      const Text('Speech is unavailable on the computer. Check its model and speech worker setup.',
          style: TextStyle(color: Color(0xFFF4C76B))),
    if (message != null) Text(message!, style: const TextStyle(color: Color(0xFFF4C76B))),
  ]);
}
