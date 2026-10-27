import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_remote/imac_session.dart';
import 'package:nexus_remote/main.dart';
import 'package:nexus_remote/session.dart';
import 'package:nexus_remote/tv_page.dart';

class FakeImacSession extends ImacSession {
  final List<String> sentCommands = [];
  final List<Map<String, dynamic>?> sentParams = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> sendCommand(String action, [Map<String, dynamic>? params]) async {
    sentCommands.add(action);
    sentParams.add(params);
  }

  @override
  Future<void> pollState() async {}
}

class FakePcRemoteSession extends RemoteSession {
  final List<String> sentKeys = [];
  final List<String> rpcMethods = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> key(String key) async {
    sentKeys.add(key);
  }

  @override
  Future<Map<String, dynamic>> rpc(String method, Map<String, dynamic> params) async {
    rpcMethods.add(method);
    if (method == 'volume.state') {
      return {'percent': 50, 'muted': false};
    }
    return {};
  }
}

void main() {
  testWidgets('TvPage renders TV controls, app buttons, and D-pad', (tester) async {
    final fakeImac = FakeImacSession()
      ..address = '192.168.68.104:8765'
      ..connected = true
      ..status = 'Connected';
    final fakePc = FakePcRemoteSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvPage(
            imacSession: fakeImac,
            pcSession: fakePc,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify machine toggle
    expect(find.text('📺 iMac TV'), findsOneWidget);
    expect(find.text('💻 PC'), findsOneWidget);

    // Verify app buttons
    expect(find.text('◆ Stremio'), findsOneWidget);
    expect(find.text('▶ YouTube'), findsOneWidget);
    expect(find.text('🎬 VLC'), findsOneWidget);
    expect(find.text('⌂ Home'), findsOneWidget);

    // Verify D-pad
    expect(find.text('▲'), findsOneWidget);
    expect(find.text('▼'), findsOneWidget);
    expect(find.text('◀'), findsOneWidget);
    expect(find.text('▶'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);

    // Verify transport
    expect(find.text('⏪ -10s'), findsOneWidget);
    expect(find.text('PLAY / PAUSE'), findsOneWidget);
    expect(find.text('+10s ⏩'), findsOneWidget);

    // Verify action buttons
    expect(find.text('↩ Back'), findsOneWidget);
    expect(find.text('ESC'), findsOneWidget);
    expect(find.text('Mute'), findsOneWidget);
    expect(find.text('⛶'), findsOneWidget);
  });

  testWidgets('TvPage dispatches D-pad and transport commands to iMac', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final fakeImac = FakeImacSession()
      ..address = '192.168.68.104:8765'
      ..connected = true;
    final fakePc = FakePcRemoteSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvPage(
            imacSession: fakeImac,
            pcSession: fakePc,
            initialTarget: 'imac',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap Up
    await tester.tap(find.text('▲'));
    await tester.pump();
    expect(fakeImac.sentCommands, contains('up'));

    // Tap OK
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(fakeImac.sentCommands, contains('ok'));

    // Tap Play/Pause
    await tester.ensureVisible(find.text('PLAY / PAUSE'));
    await tester.tap(find.text('PLAY / PAUSE'));
    await tester.pump();
    expect(fakeImac.sentCommands, contains('play'));

    // Tap Stremio app button
    await tester.tap(find.text('◆ Stremio'));
    await tester.pump();
    expect(fakeImac.sentCommands, contains('select'));
    expect(fakeImac.sentParams.last?['app'], 'stremio');
  });

  testWidgets('TvPage switches to PC and dispatches keyboard/media RPCs to PC', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final fakeImac = FakeImacSession();
    final fakePc = FakePcRemoteSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvPage(
            imacSession: fakeImac,
            pcSession: fakePc,
            initialTarget: 'imac',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Switch to PC
    await tester.tap(find.text('💻 PC'));
    await tester.pumpAndSettle();

    // Tap Up -> should send 'Up' key to PC
    await tester.tap(find.text('▲'));
    await tester.pump();
    expect(fakePc.sentKeys, contains('Up'));

    // Tap OK -> should send 'Enter' key to PC
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(fakePc.sentKeys, contains('Enter'));

    // Tap Play -> should send media.action RPC to PC
    await tester.ensureVisible(find.text('PLAY / PAUSE'));
    await tester.tap(find.text('PLAY / PAUSE'));
    await tester.pump();
    expect(fakePc.rpcMethods, contains('media.action'));
  });

  testWidgets('TvPage toggles Pointer / Touchpad mode', (tester) async {
    final fakeImac = FakeImacSession();
    final fakePc = FakePcRemoteSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvPage(
            imacSession: fakeImac,
            pcSession: fakePc,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('▲'), findsOneWidget);

    // Toggle Pointer
    await tester.ensureVisible(find.text('Pointer'));
    await tester.tap(find.text('Pointer'));
    await tester.pumpAndSettle();

    expect(find.text('Touchpad Mode'), findsOneWidget);
    expect(find.text('▲'), findsNothing);

    // Toggle back to D-Pad
    await tester.ensureVisible(find.text('D-Pad'));
    await tester.tap(find.text('D-Pad'));
    await tester.pumpAndSettle();

    expect(find.text('▲'), findsOneWidget);
    expect(find.text('Touchpad Mode'), findsNothing);
  });

  testWidgets('TvPage opens Sleep Timer modal and selects duration', (tester) async {
    final fakeImac = FakeImacSession()..connected = true;
    final fakePc = FakePcRemoteSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvPage(
            imacSession: fakeImac,
            pcSession: fakePc,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Open Sleep timer
    await tester.ensureVisible(find.text('Timer'));
    await tester.tap(find.text('Timer'));
    await tester.pumpAndSettle();

    expect(find.text('Sleep Timer'), findsOneWidget);
    expect(find.text('30 min'), findsOneWidget);

    // Select 30 min
    await tester.tap(find.text('30 min'));
    await tester.pumpAndSettle();

    expect(fakeImac.sentCommands, contains('timer'));
    expect(fakeImac.sentParams.last?['minutes'], 30);

    // Button should now show countdown instead of 'Timer' and hourglass icon
    expect(find.byIcon(Icons.hourglass_bottom_rounded), findsOneWidget);
    expect(find.text('Timer'), findsNothing);
  });

  testWidgets('MainScreen navigation opens the full TV remote connection screen', (tester) async {
    final fakePc = FakePcRemoteSession();
    final fakeImac = FakeImacSession();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(fakePc),
          imacSessionProvider.overrideWithValue(fakeImac),
        ],
        child: const NexusRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Verify TV destination exists
    expect(find.text('TV'), findsOneWidget);

    // Tap TV tab
    await tester.tap(find.text('TV'));
    await tester.pumpAndSettle();

    expect(find.text('Your TV remote'), findsOneWidget);
    expect(find.text('Open TV remote'), findsOneWidget);
    // The web remote supplies its own navigation, with no duplicate Nexus bar.
    expect(find.byType(NavigationBar), findsNothing);
  });

  test('ImacPlaybackInfo parses JSON correctly', () {
    final info = ImacPlaybackInfo.fromJson({
      'active': true,
      'title': 'The Matrix',
      'position': 120.5,
      'duration': 7200.0,
      'paused': false,
    });

    expect(info.active, isTrue);
    expect(info.title, 'The Matrix');
    expect(info.position, 120.5);
    expect(info.duration, 7200.0);
    expect(info.paused, isFalse);
  });

  testWidgets('TvPage switches from VLC to YouTube and exercises dedicated volume row', (tester) async {
    final fakeImac = FakeImacSession()
      ..connected = true
      ..app = 'vlc'
      ..volume = 12
      ..muted = false;
    final fakePc = FakePcRemoteSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvPage(
            imacSession: fakeImac,
            pcSession: fakePc,
            initialTarget: 'imac',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify initial state shows VLC and 12% volume
    expect(find.text('VLC'), findsOneWidget);
    expect(find.text('12%'), findsOneWidget);

    // Tap YouTube button
    await tester.tap(find.text('▶ YouTube'));
    await tester.pumpAndSettle();

    // Verify select command was sent with app = youtube
    expect(fakeImac.sentCommands, contains('select'));
    expect(fakeImac.sentParams.last?['app'], 'youtube');
    expect(fakeImac.app, 'youtube');
    expect(find.text('YouTube'), findsOneWidget);

    // Exercise volume controls
    await tester.ensureVisible(find.text('−'));
    await tester.tap(find.text('−'));
    await tester.pumpAndSettle();
    expect(fakeImac.sentCommands, contains('volume'));
    expect(fakeImac.sentParams.last?['direction'], -1);
    expect(fakeImac.volume, 7);

    await tester.ensureVisible(find.text('＋'));
    await tester.tap(find.text('＋'));
    await tester.pumpAndSettle();
    expect(fakeImac.sentParams.last?['direction'], 1);
    expect(fakeImac.volume, 12);

    await tester.ensureVisible(find.text('12%'));
    await tester.tap(find.text('12%'));
    await tester.pumpAndSettle();
    expect(fakeImac.sentCommands, contains('mute'));
    expect(fakeImac.muted, isTrue);
  });
}
