import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clock/clock.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import 'session.dart';
import 'audio.dart';

class HoldToTranscribeButton extends StatefulWidget {
  const HoldToTranscribeButton({
    super.key,
    required this.session,
    this.language = 'auto',
    this.recorder,
  });

  final RemoteSession session;
  final String language;
  final AudioRecorder? recorder;

  @override
  State<HoldToTranscribeButton> createState() => _HoldToTranscribeButtonState();
}

class _HoldToTranscribeButtonState extends State<HoldToTranscribeButton> with WidgetsBindingObserver {
  late final AudioRecorder _recorder;
  bool _ownsRecorder = false;
  Timer? _timer;
  DateTime? _started;
  bool _isHolding = false;
  bool _recording = false;
  bool _processing = false;
  bool _cancelling = false;
  int _seconds = 0;
  String? _statusMessage;
  Offset _dragStart = Offset.zero;
  int? _activePointerId;
  String? _currentRecordingPath;
  Completer<void>? _startCompleter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.recorder != null) {
      _recorder = widget.recorder!;
      _ownsRecorder = false;
    } else {
      _recorder = AudioRecorder();
      _ownsRecorder = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_recording && state != AppLifecycleState.resumed) {
      _isHolding = false;
      unawaited(_stopRecording(cancelled: true, message: 'Recording cancelled'));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    if (_recording) {
      unawaited(_recorder.stop());
    }
    if (_ownsRecorder) {
      unawaited(_recorder.dispose());
    }
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      if (!widget.session.connected) {
        if (mounted) {
          setState(() => _statusMessage = 'Connect to computer to transcribe');
        }
        return;
      }
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          setState(() => _statusMessage = 'Microphone permission denied');
        }
        return;
      }
      if (!_isHolding) {
        return;
      }

      final directory = await getApplicationDocumentsDirectory();
      try {
        var retainedBytes = 0;
        for (final entry in directory.listSync()) {
          if (entry is File && entry.path.endsWith('.wav')) {
            retainedBytes += entry.lengthSync();
          }
        }
        if (retainedBytes >= 100 * 1024 * 1024) {
          throw StateError('Recording storage is full');
        }
      } catch (e) {
        if (e is StateError) rethrow;
      }

      final path = '${directory.path}/${const Uuid().v4()}.wav';
      _currentRecordingPath = path;

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          audioInterruption: AudioInterruptionMode.pause,
        ),
        path: path,
      );

      if (!_isHolding) {
        final stopped = await _recorder.stop();
        final toDelete = stopped ?? _currentRecordingPath;
        if (toDelete != null) {
          final file = File(toDelete);
          if (file.existsSync()) file.deleteSync();
        }
        _currentRecordingPath = null;
        return;
      }

      HapticFeedback.heavyImpact();
      if (mounted) {
        setState(() {
          _recording = true;
          _seconds = 0;
          _statusMessage = null;
        });
      }

      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final s = clock.now().difference(_started!).inSeconds;
        setState(() => _seconds = s);
        if (s >= 300) {
          unawaited(_stopRecording(cancelled: false));
        }
      });
    } catch (e) {
      if (mounted) setState(() => _statusMessage = e.toString());
    } finally {
      _startCompleter?.complete();
    }
  }

  Future<void> _stopRecording({required bool cancelled, String? message}) async {
    _timer?.cancel();
    if (_startCompleter != null && !_startCompleter!.isCompleted) {
      await _startCompleter!.future;
    }

    if (!_recording && _currentRecordingPath == null) {
      if (message != null && mounted) {
        setState(() {
          _recording = false;
          _statusMessage = message;
          _cancelling = false;
        });
      }
      return;
    }

    if (cancelled) {
      HapticFeedback.mediumImpact();
      try {
        final stoppedPath = await _recorder.stop();
        final path = stoppedPath ?? _currentRecordingPath;
        if (path != null) {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        }
      } catch (_) {}
      _currentRecordingPath = null;
      if (mounted) {
        setState(() {
          _recording = false;
          _statusMessage = message ?? 'Recording cancelled';
          _cancelling = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _recording = false;
        _processing = true;
        _statusMessage = 'Transcribing on computer…';
      });
    }
    HapticFeedback.mediumImpact();

    try {
      final stoppedPath = await _recorder.stop();
      final path = stoppedPath ?? _currentRecordingPath;
      if (path == null) throw StateError('Recording could not be saved');
      _currentRecordingPath = null;

      await AudioNormalizer.normalize(File(path));
      final text = await widget.session.transcribeRecording(path, language: widget.language);

      if (text.isEmpty) {
        if (mounted) {
          setState(() => _statusMessage = 'No speech detected');
        }
        return;
      }

      if (widget.session.connected && widget.session.inputSupported) {
        if (mounted) {
          setState(() => _statusMessage = 'Inserting into PC…');
        }
        await widget.session.insert(text);
        HapticFeedback.lightImpact();
        if (mounted) {
          final cleanText = text.replaceAll('\n', ' ').trim();
          final preview = cleanText.length > 28 ? '${cleanText.substring(0, 28)}…' : cleanText;
          setState(() => _statusMessage = 'Typed on PC: "$preview"');
        }
      } else {
        if (mounted) {
          final cleanText = text.replaceAll('\n', ' ').trim();
          final preview = cleanText.length > 28 ? '${cleanText.substring(0, 28)}…' : cleanText;
          setState(() => _statusMessage = 'Saved to draft: "$preview"');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = 'Transcription error: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _cancelling = false;
        });
      }
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_processing) return;
    _activePointerId = event.pointer;
    _dragStart = event.position;
    _started = clock.now();
    _isHolding = true;
    _cancelling = false;
    _startCompleter = Completer<void>();
    unawaited(_startRecording());
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointerId) return;
    if (!_recording) return;

    final distance = (event.position - _dragStart).distance;
    if (distance > 70) {
      if (!_cancelling) {
        HapticFeedback.selectionClick();
        setState(() => _cancelling = true);
      }
    } else {
      if (_cancelling) {
        setState(() => _cancelling = false);
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointerId) return;
    _activePointerId = null;
    _isHolding = false;

    final duration = _started != null ? clock.now().difference(_started!) : Duration.zero;
    if (_cancelling) {
      unawaited(_stopRecording(cancelled: true, message: 'Recording cancelled'));
    } else if (duration.inMilliseconds < 350) {
      unawaited(_stopRecording(cancelled: true, message: 'Hold to record prompt'));
    } else {
      unawaited(_stopRecording(cancelled: false));
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _activePointerId) {
      _activePointerId = null;
      _isHolding = false;
      unawaited(_stopRecording(cancelled: true, message: 'Recording cancelled'));
    }
  }

  String _formatDuration(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isRecording = _recording;
    final isProcessing = _processing;
    final isCancelling = _cancelling;

    final Color bgColor;
    final Color borderColor;
    final Widget leadingWidget;
    final String titleText;
    final String subtitleText;
    final Color subtitleColor;

    if (isCancelling) {
      bgColor = const Color(0xFF3B1A20);
      borderColor = const Color(0xFFFF5252);
      leadingWidget = Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: Color(0xFFD32F2F),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.close, color: Colors.white, size: 24),
      );
      titleText = 'Release to cancel';
      subtitleText = 'Recording will be discarded';
      subtitleColor = const Color(0xFFFF8A80);
    } else if (isRecording) {
      bgColor = const Color(0xFF331418);
      borderColor = const Color(0xFFE53935);
      leadingWidget = Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: Color(0xFFE53935),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.mic, color: Colors.white, size: 26),
      );
      titleText = 'Recording (${_formatDuration(_seconds)})';
      subtitleText = 'Release to transcribe · Slide away to cancel';
      subtitleColor = const Color(0xFFFFCDD2);
    } else if (isProcessing) {
      bgColor = const Color(0xFF13222B);
      borderColor = const Color(0xFF265868);
      leadingWidget = const SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Color(0xFF8AE3CB),
            ),
          ),
        ),
      );
      titleText = 'Transcribing on computer…';
      subtitleText = _statusMessage ?? 'Processing audio…';
      subtitleColor = const Color(0xFF8AE3CB);
    } else {
      bgColor = const Color(0xFF161C24);
      borderColor = const Color(0xFF2D3948);
      leadingWidget = Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF222C38),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF2D3948)),
        ),
        child: const Icon(Icons.mic, color: Color(0xFF8AE3CB), size: 24),
      );
      titleText = 'Record a prompt';
      if (!widget.session.connected) {
        subtitleText = 'Connect to computer to transcribe';
        subtitleColor = const Color(0xFFA7B3C2);
      } else {
        subtitleText = _statusMessage ?? 'Hold to speak, release to type on PC';
        subtitleColor = _statusMessage != null && _statusMessage!.startsWith('Error')
            ? const Color(0xFFFF8080)
            : const Color(0xFFA7B3C2);
      }
    }

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: isRecording ? 1.5 : 1.0),
        ),
        child: Row(
          children: [
            leadingWidget,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titleText,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitleText,
                    style: TextStyle(
                      fontSize: 12,
                      color: subtitleColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (!isRecording && !isProcessing)
              const Icon(
                Icons.touch_app,
                size: 20,
                color: Color(0xFF6B7A8D),
              ),
          ],
        ),
      ),
    );
  }
}
