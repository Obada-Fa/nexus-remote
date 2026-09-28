import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_remote/audio.dart';

Uint8List wav({required int rate, required int channels, required int frames}) {
  final output = Uint8List(44 + frames * channels * 2);
  final header = ByteData.sublistView(output);
  output.setRange(0, 4, 'RIFF'.codeUnits);
  header.setUint32(4, output.length - 8, Endian.little);
  output.setRange(8, 12, 'WAVE'.codeUnits);
  output.setRange(12, 16, 'fmt '.codeUnits);
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * channels * 2, Endian.little);
  header.setUint16(32, channels * 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  output.setRange(36, 40, 'data'.codeUnits);
  header.setUint32(40, frames * channels * 2, Endian.little);
  for (var i = 0; i < frames * channels; i++) {
    header.setInt16(44 + i * 2, 1000, Endian.little);
  }
  return output;
}

void main() {
  test('normalizes stereo 48 kHz PCM to mono 16 kHz', () async {
    final dir = await Directory.systemTemp.createTemp('nexus-audio-test-');
    try {
      final file = File('${dir.path}/input.wav');
      await file.writeAsBytes(wav(rate: 48000, channels: 2, frames: 48000));
      await AudioNormalizer.normalize(file);
      final output = ByteData.sublistView(await file.readAsBytes());
      expect(output.getUint16(22, Endian.little), 1);
      expect(output.getUint32(24, Endian.little), 16000);
      expect(output.getUint32(40, Endian.little), 32000);
      expect(output.getInt16(44, Endian.little), 1000);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('rejects malformed WAV', () async {
    final dir = await Directory.systemTemp.createTemp('nexus-audio-test-');
    try {
      final file = File('${dir.path}/input.wav');
      await file.writeAsString('not audio');
      expect(AudioNormalizer.normalize(file), throwsFormatException);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
