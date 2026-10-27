import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_remote/imac_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This integration test uses only a loopback HTTP fixture.
  HttpOverrides.global = null;
  test(
    'TV address preserves TLS and supports IPv6, rejects credentials and paths',
    () {
      expect(
        ImacSession.parseOrigin('192.168.1.20').toString(),
        'http://192.168.1.20:8765',
      );
      expect(ImacSession.parseOrigin('https://tv.test/').scheme, 'https');
      expect(ImacSession.parseOrigin('[fd00::1]:8765').host, 'fd00::1');
      for (final input in [
        'http://user:secret@tv.test',
        'http://tv.test/api/state',
        'http://tv.test?k=secret',
      ]) {
        expect(() => ImacSession.parseOrigin(input), throwsFormatException);
      }
    },
  );

  test(
    'pair reads HTTP-only cookie, sends it to commands, reports failures',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var cookie = '';
      var direction = 0;
      var failCommands = false;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/api/pair') {
          expect(jsonDecode(await utf8.decoder.bind(request).join()), {
            'code': '123456',
          });
          request.response.cookies.add(
            Cookie('imactv', 'test-paired-token')..httpOnly = true,
          );
          request.response.write('{"paired":true}');
        } else if (request.uri.path == '/api/state') {
          request.response.write('{"volume":40,"playback":{"active":false}}');
        } else {
          cookie = request.headers.value(HttpHeaders.cookieHeader) ?? '';
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          direction = body['params']['direction'] as int;
          request.response.statusCode = failCommands ? 503 : 200;
          request.response.write(
            failCommands ? '{"error":"offline"}' : '{"ok":true}',
          );
        }
        await request.response.close();
      });
      final session = ImacSession()..address = '127.0.0.1:${server.port}';
      try {
        await session.pair('123456');
        expect(session.token, 'test-paired-token');
        await session.sendCommand('volume', {'direction': 1});
        expect(cookie, contains('imactv=test-paired-token'));
        expect(direction, 1);
        failCommands = true;
        await expectLater(
          session.sendCommand('volume', {'direction': -1}),
          throwsStateError,
        );
        await session.setAddressAndToken(
          newAddress: 'localhost:${server.port}',
        );
        expect(session.token, isEmpty);
        expect(session.legacyKey, isEmpty);
      } finally {
        session.dispose();
        await server.close(force: true);
      }
    },
  );
}
