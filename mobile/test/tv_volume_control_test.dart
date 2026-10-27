import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_remote/imac_session.dart';
import 'package:nexus_remote/main.dart';
import 'package:nexus_remote/session.dart';
import 'package:nexus_remote/tv_volume_control.dart';

class TestImac extends ImacSession {
  @override
  Future<void> initialize() => hardwareVolume.initialize();
}

class TestPc extends RemoteSession {
  @override
  Future<void> initialize() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  var nativeEnabled = false;

  setUp(() {
    calls = [];
    nativeEnabled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(TvVolumeControl.channel, (call) async {
          calls.add(call);
          if (call.method == 'start') nativeEnabled = true;
          if (call.method == 'stop') nativeEnabled = false;
          return call.method == 'status' ? {'enabled': nativeEnabled} : null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(TvVolumeControl.channel, null);
  });

  testWidgets('volume session survives leaving the full-screen TV section', (
    tester,
  ) async {
    final tv = TestImac();
    final pc = TestPc();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          imacSessionProvider.overrideWithValue(tv),
          sessionProvider.overrideWithValue(pc),
        ],
        child: const NexusRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tv.hardwareVolume.start(
      origin: Uri.parse('http://tv.test:8765'),
      token: 'paired-token',
    );
    await tester.tap(find.text('TV').last);
    await tester.pumpAndSettle();
    expect(find.text('Your TV remote'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Write').last);
    await tester.pumpAndSettle();
    expect(tv.hardwareVolume.enabled, true);
    expect(calls.where((call) => call.method == 'stop'), isEmpty);
    await tv.hardwareVolume.stop();
    await tester.pumpWidget(const SizedBox());
    tv.dispose();
    pc.dispose();
  });

  testWidgets('Android bridge uses paired origin and survives UI suspension', (
    tester,
  ) async {
    final control = TvVolumeControl();
    await control.initialize();
    await control.start(
      origin: Uri.parse('http://tv.test:8765'),
      token: 'paired-token',
    );
    expect(control.enabled, true);
    final start = calls.singleWhere((call) => call.method == 'start');
    expect(start.arguments, {
      'origin': 'http://tv.test:8765',
      'cookie': 'imactv=paired-token',
    });
    control.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(calls.where((call) => call.method == 'stop'), isEmpty);
    // A notification stop is reflected when the app resumes.
    nativeEnabled = false;
    control.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(control.enabled, false);
    control.dispose();
  });

  testWidgets(
    'iPhone presents on-screen controls guidance without native calls',
    (tester) async {
      final session = TestImac();
      await session.hardwareVolume.initialize();
      expect(session.hardwareVolume.supported, false);
      expect(calls, isEmpty);
      session.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'denied notification permission leaves mode off with a useful error',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(TvVolumeControl.channel, (_) async {
            throw PlatformException(
              code: 'notifications_denied',
              message: 'Allow notifications',
            );
          });
      final control = TvVolumeControl();
      await control.start(
        origin: Uri.parse('http://tv.test:8765'),
        token: 'paired-token',
      );
      expect(control.enabled, false);
      expect(control.error, 'Allow notifications');
      expect(control.busy, false);
      control.dispose();
    },
  );
}
