import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:nexus_remote/hold_to_transcribe_button.dart';
import 'package:nexus_remote/session.dart';

class MockAudioRecorder extends Fake implements AudioRecorder {
  bool hasPermissionResult = true;
  bool recordingActive = false;
  String? currentPath;
  RecordConfig? config;

  @override
  Future<bool> hasPermission({bool request = true}) async => hasPermissionResult;

  @override
  Future<bool> isRecording() async => recordingActive;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    recordingActive = true;
    currentPath = path;
    this.config = config;
  }

  @override
  Future<String?> stop() async {
    recordingActive = false;
    return currentPath;
  }

  @override
  Future<void> dispose() async {}
}

class TestRemoteSession extends RemoteSession {
  String transcribedText = 'Hello computer';
  String lastInsertedText = '';
  int insertCallCount = 0;
  int transcribeCallCount = 0;

  @override
  Future<String> transcribeRecording(String path, {String language = 'auto'}) async {
    transcribeCallCount++;
    return transcribedText;
  }

  @override
  Future<String> insert(String text) async {
    insertCallCount++;
    lastInsertedText = text;
    return 'paste_dispatched';
  }
}

Uint8List createValidWav() {
  final output = Uint8List(44 + 16000 * 2);
  final header = ByteData.sublistView(output);
  output.setRange(0, 4, 'RIFF'.codeUnits);
  header.setUint32(4, output.length - 8, Endian.little);
  output.setRange(8, 12, 'WAVE'.codeUnits);
  output.setRange(12, 16, 'fmt '.codeUnits);
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  output.setRange(36, 40, 'data'.codeUnits);
  header.setUint32(40, 16000 * 2, Endian.little);
  return output;
}

class FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  FakePathProviderPlatform(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hold_to_transcribe_test_');
    PathProviderPlatform.instance = FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('HoldToTranscribeButton shows idle UI and disconnected state', (tester) async {
    final session = TestRemoteSession();
    session.connected = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HoldToTranscribeButton(session: session),
        ),
      ),
    );

    expect(find.text('Record a prompt'), findsOneWidget);
    expect(find.text('Connect to computer to transcribe'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
  });

  testWidgets('HoldToTranscribeButton shows ready state when connected', (tester) async {
    final session = TestRemoteSession();
    session.connected = true;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HoldToTranscribeButton(session: session),
        ),
      ),
    );

    expect(find.text('Record a prompt'), findsOneWidget);
    expect(find.text('Hold to speak, release to type on PC'), findsOneWidget);
  });

  testWidgets('Short tap triggers "Hold to record prompt" guidance', (tester) async {
    final session = TestRemoteSession();
    session.connected = true;
    final recorder = MockAudioRecorder();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HoldToTranscribeButton(
            session: session,
            recorder: recorder,
          ),
        ),
      ),
    );

    final buttonFinder = find.byType(HoldToTranscribeButton);
    final gesture = await tester.startGesture(tester.getCenter(buttonFinder));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Hold to record prompt'), findsOneWidget);
    expect(session.transcribeCallCount, 0);
  });

  testWidgets('Holding button records, releases, transcribes and inserts into PC', (tester) async {
    final session = TestRemoteSession();
    session.connected = true;
    session.inputSupported = true;
    final recorder = MockAudioRecorder();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HoldToTranscribeButton(
            session: session,
            recorder: recorder,
          ),
        ),
      ),
    );

    final buttonFinder = find.byType(HoldToTranscribeButton);
    final gesture = await tester.startGesture(tester.getCenter(buttonFinder));
    await tester.pump(const Duration(milliseconds: 100));

    // Verify recorder was started
    expect(recorder.recordingActive, isTrue);
    expect(recorder.currentPath, isNotNull);

    // Create a valid WAV at currentPath so AudioNormalizer succeeds
    final audioFile = File(recorder.currentPath!);
    audioFile.writeAsBytesSync(createValidWav());

    // Advance time past the short tap threshold (>= 350ms)
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Recording (0:00)'), findsOneWidget);

    // Release gesture
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(session.transcribeCallCount, 1);
    expect(session.insertCallCount, 1);
    expect(session.lastInsertedText, 'Hello computer');
    expect(find.text('Typed on PC: "Hello computer"'), findsOneWidget);
  });

  testWidgets('Sliding finger away cancels recording', (tester) async {
    final session = TestRemoteSession();
    session.connected = true;
    session.inputSupported = true;
    final recorder = MockAudioRecorder();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HoldToTranscribeButton(
            session: session,
            recorder: recorder,
          ),
        ),
      ),
    );

    final buttonFinder = find.byType(HoldToTranscribeButton);
    final center = tester.getCenter(buttonFinder);
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 100));

    // Move more than 70 pixels away
    await gesture.moveTo(center + const Offset(0, 100));
    await tester.pump();

    expect(find.text('Release to cancel'), findsOneWidget);
    expect(find.text('Recording will be discarded'), findsOneWidget);

    // Release while cancelled
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(session.transcribeCallCount, 0);
    expect(session.insertCallCount, 0);
    expect(find.text('Recording cancelled'), findsOneWidget);
  });
}
