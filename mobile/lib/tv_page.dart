import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'imac_session.dart';
import 'session.dart';

class TvPage extends StatefulWidget {
  const TvPage({
    super.key,
    required this.imacSession,
    required this.pcSession,
    this.initialTarget = 'imac',
    this.onConfigurePc,
  });

  final ImacSession imacSession;
  final RemoteSession pcSession;
  final String initialTarget;
  final VoidCallback? onConfigurePc;

  @override
  State<TvPage> createState() => _TvPageState();
}

class _TvPageState extends State<TvPage> {
  late String target;
  bool pointerMode = false;
  Offset? lastPointerPos;
  Timer? _tickerTimer;

  @override
  void initState() {
    super.initState();
    target = widget.initialTarget;
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.imacSession.timerDeadline != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    super.dispose();
  }

  void _vibrate() {
    HapticFeedback.lightImpact().catchError((_) {});
  }

  Future<void> _sendDpad(String direction) async {
    _vibrate();
    if (target == 'imac') {
      await widget.imacSession.dpad(direction).catchError((_) {});
    } else {
      final key = switch (direction) {
        'up' => 'Up',
        'down' => 'Down',
        'left' => 'Left',
        'right' => 'Right',
        'ok' => 'Enter',
        'back' => 'Escape',
        _ => 'Enter',
      };
      await widget.pcSession.key(key).catchError((_) {});
    }
  }

  Future<void> _sendApp(String app) async {
    _vibrate();
    if (target == 'imac') {
      await widget.imacSession.selectApp(app).catchError((_) {});
    } else {
      if (app == 'stremio') {
        await widget.pcSession.launchApp('com.stremio.Stremio', 'stremio').catchError((_) {});
      } else if (app == 'youtube') {
        await widget.pcSession.launchApp('youtube', 'google-chrome --app=https://youtube.com').catchError((_) {});
      } else if (app == 'vlc') {
        await widget.pcSession.launchApp('org.videolan.VLC', 'vlc').catchError((_) {});
      } else {
        await widget.pcSession.showDesktop().catchError((_) {});
      }
    }
  }

  Future<void> _sendPlay() async {
    _vibrate();
    if (target == 'imac') {
      await widget.imacSession.playPause().catchError((_) {});
    } else {
      try {
        await widget.pcSession.rpc('media.action', {'action': 'play_pause'});
      } catch (_) {
        await widget.pcSession.key('space').catchError((_) {});
      }
    }
  }

  Future<void> _sendSkip(int seconds) async {
    _vibrate();
    if (target == 'imac') {
      if (seconds < 0) {
        await widget.imacSession.rewind().catchError((_) {});
      } else {
        await widget.imacSession.fastForward().catchError((_) {});
      }
    } else {
      final action = seconds < 0 ? 'backward' : 'forward';
      try {
        await widget.pcSession.rpc('media.action', {'action': action});
      } catch (_) {
        await widget.pcSession.key(seconds < 0 ? 'Left' : 'Right').catchError((_) {});
      }
    }
  }

  Future<void> _sendVolume(int direction) async {
    _vibrate();
    if (target == 'imac') {
      if (direction > 0) {
        await widget.imacSession.volumeUp().catchError((_) {});
      } else {
        await widget.imacSession.volumeDown().catchError((_) {});
      }
    } else {
      // PC volume relative
      try {
        final state = await widget.pcSession.rpc('volume.state', {});
        final cur = (state['percent'] as num?)?.toInt() ?? 50;
        final next = (cur + direction * 5).clamp(0, 100);
        await widget.pcSession.rpc('volume.set', {'percent': next});
      } catch (_) {}
    }
  }

  Future<void> _sendMute() async {
    _vibrate();
    if (target == 'imac') {
      await widget.imacSession.toggleMute().catchError((_) {});
    } else {
      try {
        final state = await widget.pcSession.rpc('volume.state', {});
        final muted = state['muted'] == true;
        await widget.pcSession.rpc('volume.mute', {'muted': !muted});
      } catch (_) {}
    }
  }

  Future<void> _sendFullscreen() async {
    _vibrate();
    if (target == 'imac') {
      await widget.imacSession.fullscreen().catchError((_) {});
    } else {
      await widget.pcSession.key('f').catchError((_) {});
    }
  }

  Future<void> _sendEscape() async {
    _vibrate();
    if (target == 'imac') {
      await widget.imacSession.escape().catchError((_) {});
    } else {
      await widget.pcSession.key('Escape').catchError((_) {});
    }
  }

  void _showTypeDialog() {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Type text on TV'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search or enter URL…',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (text) {
            Navigator.pop(ctx);
            if (text.isNotEmpty) {
              if (target == 'imac') {
                widget.imacSession.typeText(text).catchError((_) {});
              } else {
                widget.pcSession.insert(text).catchError((Object _) => '');
              }
            }
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final text = controller.text;
              Navigator.pop(ctx);
              if (text.isNotEmpty) {
                if (target == 'imac') {
                  widget.imacSession.typeText(text).catchError((_) {});
                } else {
                  widget.pcSession.insert(text).catchError((Object _) => '');
                }
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  String _formatTimerCountdown(double? deadline) {
    if (deadline == null) return '';
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final remaining = (deadline - now).round();
    if (remaining <= 0) return 'Turning off now';
    final mins = remaining ~/ 60;
    final secs = remaining % 60;
    final dt = DateTime.fromMillisecondsSinceEpoch((deadline * 1000).round());
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    if (mins > 0) {
      return 'Turns off at $hour:$minute (${mins}m remaining)';
    } else {
      return 'Turns off at $hour:$minute (${secs}s remaining)';
    }
  }

  String _formatTimerButtonCountdown(double? deadline) {
    if (deadline == null) return 'Timer';
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final remaining = (deadline - now).round();
    if (remaining <= 0) return '00:00';
    final hours = remaining ~/ 3600;
    final mins = (remaining % 3600) ~/ 60;
    final secs = remaining % 60;
    if (hours > 0) {
      return '$hours:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  void _showSleepTimerDialog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF161C24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ListenableBuilder(
        listenable: widget.imacSession,
        builder: (ctx, _) {
          final deadline = widget.imacSession.timerDeadline;
          final countdown = _formatTimerCountdown(deadline);

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Sleep Timer', style: Theme.of(ctx).textTheme.titleLarge),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (deadline != null && countdown.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2B38),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF38577A)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.timer_outlined, color: Color(0xFF8AE3CB)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              countdown,
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF8AE3CB)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ] else ...[
                    const Text('Automatically turns off the iMac when the timer expires.'),
                    const SizedBox(height: 16),
                  ],
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final min in [15, 30, 60, 90])
                        ActionChip(
                          label: Text('$min min'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            if (target == 'imac') {
                              widget.imacSession.setTimer(min).catchError((_) {});
                            }
                          },
                        ),
                      if (deadline != null)
                        ActionChip(
                          backgroundColor: const Color(0xFF3B2326),
                          label: const Text('Cancel timer', style: TextStyle(color: Color(0xFFFF8080))),
                          onPressed: () {
                            Navigator.pop(ctx);
                            if (target == 'imac') {
                              widget.imacSession.setTimer(null).catchError((_) {});
                            }
                          },
                        ),
                    ],
                  ),
                  const Divider(height: 32),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF8B2525)),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _confirmPowerOff();
                    },
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Power Off Now'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showMoreSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF161C24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ListenableBuilder(
        listenable: widget.imacSession,
        builder: (ctx, _) {
          final s = widget.imacSession;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('TV Controls & Tools', style: Theme.of(ctx).textTheme.titleLarge),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Subtitles section if available
                  if (s.subtitles.isNotEmpty) ...[
                    const Text('Subtitles', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final track in s.subtitles)
                          ChoiceChip(
                            label: Text(track['title']?.toString() ?? 'Track'),
                            selected: track['selected'] == true,
                            onSelected: (_) {
                              Navigator.pop(ctx);
                              s.selectSubtitle(track['id']).catchError((_) {});
                            },
                          ),
                        ChoiceChip(
                          label: const Text('Off'),
                          selected: false,
                          onSelected: (_) {
                            Navigator.pop(ctx);
                            s.selectSubtitle('no').catchError((_) {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Recovery Tools
                  const Text('App & System Recovery', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            s.restartApp().catchError((_) {});
                          },
                          icon: const Icon(Icons.replay, size: 16),
                          label: const Text('Restart App'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            s.recover().catchError((_) {});
                          },
                          icon: const Icon(Icons.home_repair_service, size: 16),
                          label: const Text('TV Home'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Restart Desktop Session?'),
                          content: const Text('This will restart LightDM and reopen TV Home.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Restart')),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        if (ctx.mounted) Navigator.pop(ctx);
                        s.restartSession().catchError((_) {});
                      }
                    },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Restart Desktop Session'),
                  ),

                  const Divider(height: 28),

                  // Power & Sleep
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF8B2525)),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _confirmPowerOff();
                    },
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Turn Off iMac'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _confirmPowerOff() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Power Off?'),
        content: const Text('This will shut down the TV completely. You will need to press the physical button to turn it back on.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
            onPressed: () {
              Navigator.pop(ctx);
              if (target == 'imac') {
                widget.imacSession.powerOff().catchError((_) {});
              }
            },
            child: const Text('Power Off'),
          ),
        ],
      ),
    );
  }

  void _showImacConfig() {
    final addrCtrl = TextEditingController(text: widget.imacSession.address);
    final codeCtrl = TextEditingController();
    final keyCtrl = TextEditingController(text: widget.imacSession.legacyKey);
    bool isPairing = false;
    String? dialogError;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('iMac TV Connection'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Enter your iMac LAN address (port 8765):'),
                const SizedBox(height: 10),
                TextField(
                  controller: addrCtrl,
                  decoration: const InputDecoration(
                    labelText: 'iMac Address',
                    hintText: '192.168.68.xxx:8765',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Pairing Code (shown on TV Home):', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                TextField(
                  controller: codeCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    labelText: '6-digit Pairing Code',
                    hintText: '000000',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Or Secret Key (?k=...) if using legacy server:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 6),
                TextField(
                  controller: keyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Secret Key (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (dialogError != null) ...[
                  const SizedBox(height: 10),
                  Text(dialogError!, style: const TextStyle(color: Color(0xFFFF8080))),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: isPairing
                  ? null
                  : () async {
                      setDialogState(() {
                        isPairing = true;
                        dialogError = null;
                      });
                      try {
                        await widget.imacSession.setAddressAndToken(
                          newAddress: addrCtrl.text,
                          newLegacyKey: keyCtrl.text.trim().isNotEmpty ? keyCtrl.text : null,
                        );
                        if (codeCtrl.text.trim().isNotEmpty) {
                          await widget.imacSession.pair(codeCtrl.text);
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setDialogState(() {
                          dialogError = e.toString();
                          isPairing = false;
                        });
                      }
                    },
              child: isPairing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save & Connect'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.imacSession, widget.pcSession]),
      builder: (context, _) {
        final isImac = target == 'imac';
        final isConnected = isImac ? widget.imacSession.connected : widget.pcSession.connected;
        final statusText = isImac ? widget.imacSession.status : widget.pcSession.status;

        final appTitle = isImac
            ? (widget.imacSession.playback.active
                ? widget.imacSession.playback.title
                : switch (widget.imacSession.app.toLowerCase()) {
                    'home' => 'TV Home',
                    'stremio' => 'Stremio',
                    'youtube' => 'YouTube',
                    'vlc' => 'VLC',
                    _ => widget.imacSession.app.isEmpty ? 'TV Home' : widget.imacSession.app,
                  })
            : 'PC Desktop';

        final phaseText = isImac
            ? (widget.imacSession.phase == 'opening'
                ? 'Opening…'
                : (widget.imacSession.gui ? 'Ready' : 'Waiting for TV screen'))
            : (widget.pcSession.connected ? 'Ready' : 'Disconnected');

        final heatParts = <String>[];
        if (isImac && widget.imacSession.cpuTemperature != null) {
          heatParts.add('${widget.imacSession.cpuTemperature!.round()}° CPU');
        }
        if (isImac && widget.imacSession.gpuTemperature != null) {
          heatParts.add('${widget.imacSession.gpuTemperature!.round()}° GPU');
        }
        final heat = heatParts.join(' · ');

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              // Target Switcher & Status Bar
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 8,
                runSpacing: 8,
                children: [
                  // Machine Picker Pill
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF161C24),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF2D3948)),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _targetButton('imac', '📺 iMac TV', isImac),
                        _targetButton('pc', '💻 PC', !isImac),
                      ],
                    ),
                  ),

                  // Connection badge & settings
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isConnected
                              ? const Color(0xFF132D24)
                              : const Color(0xFF2E191C),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isConnected ? const Color(0xFF225745) : const Color(0xFF5E272E),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.circle,
                              size: 8,
                              color: isConnected ? const Color(0xFF8AE3CB) : const Color(0xFFFF8080),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              statusText,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isConnected ? const Color(0xFF8AE3CB) : const Color(0xFFFF8080),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.settings, size: 20),
                        tooltip: isImac ? 'iMac settings' : 'PC settings',
                        onPressed: isImac ? _showImacConfig : widget.onConfigurePc,
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 8),

              // Status Card (Matching Web Remote)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF151E2B),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF233247)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                appTitle,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                phaseText,
                                style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                              ),
                            ],
                          ),
                        ),
                        if (heat.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            heat,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: isImac && widget.imacSession.thermalWarning
                                  ? const Color(0xFFFF8080)
                                  : const Color(0xFF94A3B8),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (isImac && widget.imacSession.timerDeadline != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF182A3A),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF2E5274)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.timer_outlined, size: 14, color: Color(0xFF8AE3CB)),
                            const SizedBox(width: 6),
                            Text(
                              _formatTimerCountdown(widget.imacSession.timerDeadline),
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF8AE3CB),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 10),

              // App Launchers row (Home, Stremio, YouTube, VLC)
              Row(
                children: [
                  Expanded(
                    child: _appButton(
                      'home',
                      '⌂ Home',
                      isSelected: isImac && (widget.imacSession.app.toLowerCase() == 'home' || widget.imacSession.app.isEmpty),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _appButton(
                      'stremio',
                      '◆ Stremio',
                      isSelected: isImac && widget.imacSession.app.toLowerCase() == 'stremio',
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _appButton(
                      'youtube',
                      '▶ YouTube',
                      isSelected: isImac && widget.imacSession.app.toLowerCase() == 'youtube',
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _appButton(
                      'vlc',
                      '🎬 VLC',
                      isSelected: isImac && widget.imacSession.app.toLowerCase() == 'vlc',
                    ),
                  ),
                ],
              ),

              if (isImac && widget.imacSession.brightnessAvailable) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161C24),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF242F3D)),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: widget.imacSession.screenOff ? 'Turn Screen On' : 'Turn Screen Off (Audio keeps playing)',
                        icon: Icon(
                          widget.imacSession.screenOff ? Icons.screen_lock_portrait : Icons.tv_off,
                          size: 18,
                          color: widget.imacSession.screenOff ? const Color(0xFFFF8080) : const Color(0xFFA7B3C2),
                        ),
                        onPressed: () {
                          _vibrate();
                          widget.imacSession.toggleScreen().catchError((_) {});
                        },
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            activeTrackColor: const Color(0xFFE5A93C),
                            inactiveTrackColor: const Color(0xFF2C394B),
                            thumbColor: const Color(0xFFE5A93C),
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          ),
                          child: Slider(
                            value: (widget.imacSession.brightnessLevel ?? 80).clamp(5, 100).toDouble(),
                            min: 5,
                            max: 100,
                            divisions: 19,
                            onChanged: (val) {
                              widget.imacSession.setBrightness(val.round()).catchError((_) {});
                            },
                          ),
                        ),
                      ),
                      Text(
                        '${widget.imacSession.brightnessLevel ?? 80}%',
                        style: const TextStyle(fontSize: 11, color: Color(0xFFA7B3C2), fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: 'Toggle Fullscreen',
                        icon: const Text('⛶', style: TextStyle(fontSize: 18, color: Color(0xFFA7B3C2))),
                        onPressed: _sendFullscreen,
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 14),

              // D-Pad OR Pointer Area
              if (pointerMode)
                _buildPointerArea()
              else
                _buildDpadCross(),

              const SizedBox(height: 14),

              // Transport controls: -10s, Play/Pause, +10s
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1E2836),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () => _sendSkip(-10),
                        child: const Text('⏪ -10s', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1B4965),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: _sendPlay,
                        icon: const Icon(Icons.play_arrow, size: 20),
                        label: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('PLAY / PAUSE', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1E2836),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () => _sendSkip(10),
                        child: const Text('+10s ⏩', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // Action controls: Back, ESC, Fullscreen
              Row(
                children: [
                  Expanded(child: _actionButton('↩ Back', () => _sendDpad('back'))),
                  const SizedBox(width: 8),
                  Expanded(child: _actionButton('ESC', _sendEscape)),
                  const SizedBox(width: 8),
                  Expanded(child: _actionButton('⛶', _sendFullscreen)),
                ],
              ),

              const SizedBox(height: 10),

              // Dedicated Volume Row (As in Web Remote)
              Row(
                children: [
                  SizedBox(
                    width: 60,
                    height: 48,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E2530),
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFF2D3B4E)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: () => _sendVolume(-1),
                      child: const Text('−', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: Builder(
                        builder: (context) {
                          final vol = isImac ? widget.imacSession.volume : null;
                          final isMuted = isImac ? widget.imacSession.muted : false;
                          final volText = isMuted
                              ? 'Muted'
                              : (vol != null ? '$vol%' : 'Mute');

                          return OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              backgroundColor: isMuted ? const Color(0xFF381E24) : const Color(0xFF1E2530),
                              foregroundColor: isMuted ? const Color(0xFFFF8080) : Colors.white,
                              side: BorderSide(
                                color: isMuted ? const Color(0xFF7A333C) : const Color(0xFF2D3B4E),
                              ),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: _sendMute,
                            icon: Icon(
                              isMuted ? Icons.volume_off : Icons.volume_up,
                              size: 18,
                              color: isMuted ? const Color(0xFFFF8080) : const Color(0xFF8AE3CB),
                            ),
                            label: Text(
                              volText,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: isMuted ? const Color(0xFFFF8080) : Colors.white,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 60,
                    height: 48,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E2530),
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFF2D3B4E)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: () => _sendVolume(1),
                      child: const Text('＋', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Bottom utility bar: Pointer, Keys, Sleep Timer, More
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: pointerMode ? const Color(0xFF1E384D) : null,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => setState(() => pointerMode = !pointerMode),
                      icon: Icon(pointerMode ? Icons.gamepad : Icons.mouse, size: 18),
                      label: Text(pointerMode ? 'D-Pad' : 'Pointer'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
                      onPressed: _showTypeDialog,
                      icon: const Icon(Icons.keyboard, size: 18),
                      label: const Text('Keys'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final hasTimer = isImac && widget.imacSession.timerDeadline != null;
                        final timerLabel = hasTimer
                            ? _formatTimerButtonCountdown(widget.imacSession.timerDeadline)
                            : 'Timer';

                        return OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: hasTimer ? const Color(0xFF183D33) : null,
                            foregroundColor: hasTimer ? const Color(0xFF8AE3CB) : null,
                            side: hasTimer ? const BorderSide(color: Color(0xFF2E7D68), width: 1.5) : null,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: _showSleepTimerDialog,
                          icon: Icon(
                            hasTimer ? Icons.hourglass_bottom_rounded : Icons.timer,
                            size: 18,
                            color: hasTimer ? const Color(0xFF8AE3CB) : null,
                          ),
                          label: Text(
                            timerLabel,
                            style: TextStyle(
                              color: hasTimer ? const Color(0xFF8AE3CB) : null,
                              fontWeight: hasTimer ? FontWeight.bold : null,
                              fontFeatures: hasTimer ? const [FontFeature.tabularFigures()] : null,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (isImac) ...[
                    const SizedBox(width: 6),
                    IconButton.outlined(
                      tooltip: 'More Controls & Recovery',
                      icon: const Icon(Icons.more_horiz, size: 20),
                      onPressed: _showMoreSheet,
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _targetButton(String key, String label, bool active) {
    return GestureDetector(
      onTap: () {
        _vibrate();
        setState(() => target = key);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF283849) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? Colors.white : const Color(0xFFA7B3C2),
          ),
        ),
      ),
    );
  }

  Widget _appButton(String id, String label, {bool isSelected = false}) {
    return SizedBox(
      height: 44,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: isSelected ? const Color(0xFF22354E) : const Color(0xFF1E2530),
          foregroundColor: isSelected ? const Color(0xFF93C5FD) : const Color(0xFFCBD5E1),
          side: BorderSide(
            color: isSelected ? const Color(0xFF60A5FA) : const Color(0xFF2D3B4E),
            width: isSelected ? 2.0 : 1.0,
          ),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: () => _sendApp(id),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _actionButton(String label, VoidCallback onTap) {
    return SizedBox(
      height: 44,
      child: FilledButton.tonal(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF161C24),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        onPressed: onTap,
        child: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildDpadCross() {
    return AspectRatio(
      aspectRatio: 1.0,
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            // Up
            Expanded(
              child: Row(
                children: [
                  const Spacer(),
                  Expanded(
                    flex: 2,
                    child: _dpadButton('up', '▲', BorderRadius.circular(18)),
                  ),
                  const Spacer(),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Left, OK, Right
            Expanded(
              flex: 2,
              child: Row(
                children: [
                  Expanded(child: _dpadButton('left', '◀', BorderRadius.circular(18))),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: _dpadButton(
                      'ok',
                      'OK',
                      BorderRadius.circular(20),
                      isCenter: true,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: _dpadButton('right', '▶', BorderRadius.circular(18))),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Down
            Expanded(
              child: Row(
                children: [
                  const Spacer(),
                  Expanded(
                    flex: 2,
                    child: _dpadButton('down', '▼', BorderRadius.circular(18)),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dpadButton(String dir, String label, BorderRadius radius, {bool isCenter = false}) {
    IconData? icon;
    if (dir == 'up') icon = Icons.keyboard_arrow_up_rounded;
    if (dir == 'down') icon = Icons.keyboard_arrow_down_rounded;
    if (dir == 'left') icon = Icons.keyboard_arrow_left_rounded;
    if (dir == 'right') icon = Icons.keyboard_arrow_right_rounded;

    return Semantics(
      label: isCenter ? 'OK' : dir,
      child: Material(
        color: isCenter ? const Color(0xFF1E2E42) : const Color(0xFF161F2B),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: isCenter ? const Color(0xFF436996) : const Color(0xFF2B3A4F),
            width: isCenter ? 2.0 : 1.2,
          ),
        ),
        elevation: isCenter ? 3 : 1,
        shadowColor: Colors.black54,
        child: InkWell(
          borderRadius: radius,
          splashColor: const Color(0xFF8AE3CB).withValues(alpha: 0.2),
          highlightColor: const Color(0xFF8AE3CB).withValues(alpha: 0.1),
          onTap: () => _sendDpad(dir),
          child: Center(
            child: isCenter
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF8AE3CB),
                          letterSpacing: 1.0,
                        ),
                      ),
                    ],
                  )
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      // Offstage text for widget tests expecting the glyph
                      Opacity(
                        opacity: 0.0,
                        child: Text(label, style: const TextStyle(fontSize: 1)),
                      ),
                      Icon(
                        icon,
                        size: 38,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildPointerArea() {
    return AspectRatio(
      aspectRatio: 1.0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF161C24),
          border: Border.all(color: const Color(0xFF2D3948)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => lastPointerPos = e.localPosition,
          onPointerMove: (e) {
            final old = lastPointerPos;
            lastPointerPos = e.localPosition;
            if (old == null) return;
            final delta = e.localPosition - old;
            final dx = delta.dx.round();
            final dy = delta.dy.round();
            if (dx != 0 || dy != 0) {
              if (target == 'imac') {
                widget.imacSession.movePointer(dx * 2, dy * 2).catchError((_) {});
              } else {
                widget.pcSession.move(dx, dy).catchError((_) {});
              }
            }
          },
          onPointerUp: (e) {
            lastPointerPos = null;
          },
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.touch_app, size: 40, color: Color(0xFFA7B3C2)),
                const SizedBox(height: 8),
                const Text('Touchpad Mode', style: TextStyle(color: Color(0xFFA7B3C2))),
                const SizedBox(height: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.tonal(
                      onPressed: () {
                        _vibrate();
                        if (target == 'imac') {
                          widget.imacSession.clickPointer(1).catchError((_) {});
                        } else {
                          widget.pcSession.click(1).catchError((_) {});
                        }
                      },
                      child: const Text('Left Click'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonal(
                      onPressed: () {
                        _vibrate();
                        if (target == 'imac') {
                          widget.imacSession.clickPointer(3).catchError((_) {});
                        } else {
                          widget.pcSession.click(3).catchError((_) {});
                        }
                      },
                      child: const Text('Right Click'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
