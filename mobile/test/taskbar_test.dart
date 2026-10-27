import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_remote/app_icon.dart';
import 'package:nexus_remote/session.dart';
import 'package:nexus_remote/taskbar.dart';

class MockTaskbarSession extends RemoteSession {
  final List<String> activated = [];
  final List<String> minimized = [];
  final List<String> maximized = [];
  final List<String> closed = [];
  final List<String> launched = [];
  bool didShowDesktop = false;

  @override
  Future<void> activateWindow(String windowId) async {
    activated.add(windowId);
  }

  @override
  Future<void> minimizeWindow(String windowId) async {
    minimized.add(windowId);
  }

  @override
  Future<void> maximizeWindow(String windowId) async {
    maximized.add(windowId);
  }

  @override
  Future<void> closeWindow(String windowId) async {
    closed.add(windowId);
  }

  @override
  Future<void> showDesktop() async {
    didShowDesktop = true;
  }

  @override
  Future<void> launchApp(String appId, [String? exec]) async {
    launched.add(appId);
  }

  @override
  Future<void> refreshWindows() async {}

  @override
  Future<void> refreshApps() async {}
}

void main() {
  group('DesktopWindow & DesktopApp model parsing', () {
    test('parses DesktopWindow from JSON', () {
      final json = {
        'id': '0x05200004',
        'desktop': 0,
        'wm_class': 'org.gnome.Nautilus',
        'title': 'Projects',
        'app_name': 'Files',
        'is_active': true,
        'is_minimized': false,
        'is_maximized': true,
        'icon': 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      };
      final w = DesktopWindow.fromJson(json);
      expect(w.id, '0x05200004');
      expect(w.desktop, 0);
      expect(w.wmClass, 'org.gnome.Nautilus');
      expect(w.title, 'Projects');
      expect(w.appName, 'Files');
      expect(w.isActive, isTrue);
      expect(w.isMinimized, isFalse);
      expect(w.isMaximized, isTrue);
      expect(w.icon, startsWith('data:image/png;base64,'));
    });

    test('parses DesktopApp from JSON', () {
      final json = {
        'id': 'kitty',
        'name': 'Kitty Terminal',
        'icon': null,
        'exec': 'kitty',
      };
      final app = DesktopApp.fromJson(json);
      expect(app.id, 'kitty');
      expect(app.name, 'Kitty Terminal');
      expect(app.icon, isNull);
      expect(app.exec, 'kitty');
    });
  });

  group('OpenAppsBar widget tests', () {
    testWidgets('renders open apps with active highlight', (tester) async {
      final session = MockTaskbarSession()
        ..connected = true
        ..windowsSupported = true
        ..openWindows = [
          const DesktopWindow(
            id: '0x1',
            desktop: 0,
            wmClass: 'kitty',
            title: 'agy terminal',
            appName: 'Kitty',
            isActive: false,
            isMinimized: false,
            isMaximized: false,
          ),
          const DesktopWindow(
            id: '0x2',
            desktop: 0,
            wmClass: 'nautilus',
            title: 'Desktop',
            appName: 'Files',
            isActive: true,
            isMinimized: false,
            isMaximized: true,
          ),
        ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: OpenAppsBar(session: session),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Dash'), findsOneWidget);
      expect(find.byType(AppIconTile), findsNWidgets(2));

      // Tap inactive window '0x1' -> activates it
      await tester.tap(find.byType(AppIconTile).first);
      await tester.pumpAndSettle();
      expect(session.activated, contains('0x1'));

      // Tap active window '0x2' -> minimizes it (like Windows / Zorin taskbar)
      await tester.tap(find.byType(AppIconTile).last);
      await tester.pumpAndSettle();
      expect(session.minimized, contains('0x2'));

      // Tap Show Desktop button
      await tester.tap(find.byIcon(Icons.desktop_windows_outlined));
      await tester.pumpAndSettle();
      expect(session.didShowDesktop, isTrue);
    });

    testWidgets('long press opens window action sheet', (tester) async {
      final session = MockTaskbarSession()
        ..connected = true
        ..windowsSupported = true
        ..openWindows = [
          const DesktopWindow(
            id: '0x1',
            desktop: 0,
            wmClass: 'kitty',
            title: 'agy terminal',
            appName: 'Kitty',
            isActive: false,
            isMinimized: false,
            isMaximized: false,
          ),
        ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: OpenAppsBar(session: session),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(AppIconTile));
      await tester.pumpAndSettle();

      expect(find.text('Bring to Front (Focus)'), findsOneWidget);
      expect(find.text('Maximize'), findsOneWidget);
      expect(find.text('Minimize'), findsOneWidget);
      expect(find.text('Close Window'), findsOneWidget);

      // Tap Maximize
      await tester.tap(find.text('Maximize'));
      await tester.pumpAndSettle();
      expect(session.maximized, contains('0x1'));
    });

    testWidgets('Dash button opens StartMenuSheet with windows and apps', (tester) async {
      final session = MockTaskbarSession()
        ..connected = true
        ..windowsSupported = true
        ..openWindows = [
          const DesktopWindow(
            id: '0x1',
            desktop: 0,
            wmClass: 'kitty',
            title: 'agy terminal',
            appName: 'Kitty',
            isActive: true,
            isMinimized: false,
            isMaximized: false,
          ),
        ]
        ..installedApps = [
          const DesktopApp(
            id: 'nautilus',
            name: 'Files',
            exec: 'nautilus',
          ),
          const DesktopApp(
            id: 'firefox',
            name: 'Firefox',
            exec: 'firefox',
          ),
        ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: OpenAppsBar(session: session),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Dash'));
      await tester.pumpAndSettle();

      expect(find.text('OPEN WINDOWS (1)'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('APPLICATIONS'), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Firefox'), findsOneWidget);

      // Search filters
      await tester.enterText(find.byType(TextField), 'Fire');
      await tester.pumpAndSettle();

      expect(find.text('Firefox'), findsOneWidget);
      expect(find.text('Files'), findsNothing);

      // Tap app launches it
      await tester.tap(find.text('Firefox'));
      await tester.pumpAndSettle();

      expect(session.launched, contains('firefox'));
    });
  });
}
