import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_remote/main.dart';
import 'package:nexus_remote/session.dart';

class FakeRemoteSession extends RemoteSession {
  bool shouldFailPair = false;
  final List<Offset> moves = [];

  @override
  Future<void> move(int dx, int dy) async {
    moves.add(Offset(dx.toDouble(), dy.toDouble()));
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> pair({
    required String address,
    required String fingerprint,
    required String code,
  }) async {
    if (shouldFailPair) {
      throw StateError('Invalid pairing code');
    }
    status = 'Pairing';
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    connected = true;
    status = 'Connected';
    inputSupported = true;
    notifyListeners();
  }

  @override
  Future<void> updateAddress(String newAddress, {String? newFingerprint}) async {
    address = newAddress;
    if (newFingerprint != null) fingerprint = newFingerprint;
    status = 'Connecting';
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    connected = true;
    status = 'Connected';
    inputSupported = true;
    notifyListeners();
  }

  @override
  Future<void> retry() async {
    status = 'Connecting';
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    connected = true;
    status = 'Connected';
    inputSupported = true;
    notifyListeners();
  }

  @override
  Future<void> forgetHost() async {
    hostId = '';
    address = '';
    fingerprint = '';
    connected = false;
    status = 'Not paired';
    notifyListeners();
  }
}

void main() {
  testWidgets('MainScreen smoke test', (tester) async {
    final fakeSession = FakeRemoteSession();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(fakeSession),
        ],
        child: const NexusRemoteApp(),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Nexus Remote'), findsOneWidget);
  });

  testWidgets('MainScreen pair flow succeeds without disposed controller crash', (tester) async {
    final fakeSession = FakeRemoteSession();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(fakeSession),
        ],
        child: const NexusRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Not paired'));
    await tester.pumpAndSettle();

    expect(find.text('Pair computer'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Pairing code'), '123456');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pair'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();

    expect(find.text('Controlling computer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MainScreen pair failure displays inline error without crash', (tester) async {
    final fakeSession = FakeRemoteSession()..shouldFailPair = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(fakeSession),
        ],
        child: const NexusRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Not paired'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Pairing code'), '999999');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(find.text('Bad state: Invalid pairing code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cancelling pair dialog while field is focused does not crash', (tester) async {
    final fakeSession = FakeRemoteSession();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(fakeSession),
        ],
        child: const NexusRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Not paired'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Pairing code'), '123456');
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();

    expect(find.text('Pair computer'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Touchpad speed chip displays and opens settings modal', (tester) async {
    final fakeSession = FakeRemoteSession();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(fakeSession),
        ],
        child: const NexusRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1.75x'), findsOneWidget);

    await tester.tap(find.text('1.75x'));
    await tester.pumpAndSettle();

    expect(find.text('Touchpad Speed'), findsOneWidget);
    expect(find.text('Precision Mode'), findsOneWidget);

    // Tap 2.5x preset
    await tester.tap(find.text('2.5x (Fast)'));
    await tester.pumpAndSettle();

    expect(fakeSession.touchpadSensitivity, 2.5);

    // Toggle Precision Mode
    await tester.tap(find.widgetWithText(SwitchListTile, 'Precision Mode'));
    await tester.pumpAndSettle();

    expect(fakeSession.precisionMode, isTrue);

    // Close dialog
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('2.5x (slow)'), findsOneWidget);
  });

  testWidgets('Touchpad movement scales delta by sensitivity multiplier', (tester) async {
    final fakeSession = FakeRemoteSession()..touchpadSensitivity = 2.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Touchpad(session: fakeSession),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(find.byType(Touchpad)));
    await tester.pump(const Duration(milliseconds: 10));

    // Move 10 pixels horizontally (exceeds 8px tap tolerance)
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pumpAndSettle();

    // 10 px * 2.0 = 20
    expect(fakeSession.moves, isNotEmpty);
    final totalX = fakeSession.moves.map((m) => m.dx).reduce((a, b) => a + b);
    expect(totalX, 20.0);
  });

  testWidgets('Connection settings allows updating IP without pairing code when already paired', (tester) async {
    final fakeSession = FakeRemoteSession()
      ..hostId = 'existing-host-123'
      ..address = '192.168.1.237:45679'
      ..status = 'Disconnected';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(fakeSession),
        ],
        child: const NexusRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Disconnected'), findsWidgets);
    expect(find.text('Target: 192.168.1.237:45679'), findsOneWidget);

    // Tap Change IP / Host button from the banner
    await tester.tap(find.text('Change IP / Host'));
    await tester.pumpAndSettle();

    expect(find.text('Connection settings'), findsOneWidget);
    expect(find.text('Save & Connect'), findsOneWidget);

    // Update IP to new address
    await tester.enterText(find.widgetWithText(TextField, 'Computer address'), '192.168.68.240:45679');
    await tester.pumpAndSettle();

    // Tap Save & Connect without needing pairing code
    await tester.tap(find.text('Save & Connect'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();

    expect(fakeSession.address, '192.168.68.240:45679');
    expect(fakeSession.connected, isTrue);
    expect(find.text('Controlling computer'), findsOneWidget);
  });

  testWidgets('Connection settings allows re-pairing and forgetting host', (tester) async {
    final fakeSession = FakeRemoteSession()
      ..hostId = 'host-to-forget'
      ..address = '10.0.0.1:45679'
      ..status = 'Disconnected';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(fakeSession),
        ],
        child: const NexusRemoteApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Tap settings icon in AppBar
    await tester.tap(find.byIcon(Icons.settings_ethernet));
    await tester.pumpAndSettle();

    expect(find.text('Connection settings'), findsOneWidget);
    expect(find.text('Re-pair with new code'), findsOneWidget);

    // Expand pairing code fields
    await tester.tap(find.text('Re-pair with new code'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Pairing code'), findsOneWidget);

    // Tap Forget
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();

    expect(find.text('Forget computer?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
    await tester.pumpAndSettle();

    expect(fakeSession.hostId, isEmpty);
    expect(fakeSession.status, 'Not paired');
  });

  test('RemoteSession updateAddress normalizes ws, wss, and trailing slashes', () async {
    final session = RemoteSession();
    // Valid inputs
    expect(() => session.updateAddress('192.168.68.240:45679'), returnsNormally);
    expect(() => session.updateAddress('ws://192.168.68.240:45679/'), returnsNormally);
    expect(() => session.updateAddress('wss://100.108.139.27:45679/ws'), returnsNormally);
    expect(() => session.updateAddress('192.168.68.240'), returnsNormally);

    // Invalid input
    expect(() => session.updateAddress(''), throwsA(isA<FormatException>()));
  });
}
