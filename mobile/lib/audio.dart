import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Validates the actual recorder output and writes mono 16 kHz PCM16 WAV.
class AudioNormalizer {
  static Future<void> normalize(File file) async {
    final source = await file.readAsBytes();
    if (source.length < 44 || _tag(source, 0) != 'RIFF' || _tag(source, 8) != 'WAVE') {
      throw const FormatException('Recorder did not produce a WAV file');
    }
    final bytes = ByteData.sublistView(source);
    int? channels;
    int? rate;
    int? bits;
    int? format;
    int? dataStart;
    int? dataLength;
    var offset = 12;
    while (offset + 8 <= source.length) {
      final size = bytes.getUint32(offset + 4, Endian.little);
      final begin = offset + 8;
      if (size > source.length - begin) throw const FormatException('WAV chunk is truncated');
      final tag = _tag(source, offset);
      if (tag == 'fmt ') {
        if (size < 16) throw const FormatException('Invalid WAV format chunk');
        format = bytes.getUint16(begin, Endian.little);
        channels = bytes.getUint16(begin + 2, Endian.little);
        rate = bytes.getUint32(begin + 4, Endian.little);
        bits = bytes.getUint16(begin + 14, Endian.little);
      } else if (tag == 'data') {
        dataStart = begin;
        dataLength = size;
      }
      offset = begin + size + (size & 1);
    }
    if (format != 1 || bits != 16 || (channels != 1 && channels != 2) ||
        rate == null || rate < 8000 || rate > 96000 ||
        dataStart == null || dataLength == null || dataLength == 0 ||
        dataLength % (2 * channels!) != 0) {
      throw const FormatException('Unsupported microphone audio format');
    }
    final frames = dataLength ~/ (2 * channels);
    if (frames / rate > 300.1) throw const FormatException('Recording exceeds five minutes');
    if (channels == 1 && rate == 16000 && source.length <= 10 * 1024 * 1024) return;
    final samples = Float64List(frames);
    for (var frame = 0; frame < frames; frame++) {
      var sum = 0.0;
      for (var channel = 0; channel < channels; channel++) {
        sum += bytes.getInt16(dataStart + (frame * channels + channel) * 2, Endian.little);
      }
      samples[frame] = sum / channels;
    }
    final count = (frames * 16000 / rate).round();
    final output = Uint8List(44 + count * 2);
    final header = ByteData.sublistView(output);
    _writeTag(output, 0, 'RIFF');
    header.setUint32(4, output.length - 8, Endian.little);
    _writeTag(output, 8, 'WAVE');
    _writeTag(output, 12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, 16000, Endian.little);
    header.setUint32(28, 32000, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    _writeTag(output, 36, 'data');
    header.setUint32(40, count * 2, Endian.little);
    for (var i = 0; i < count; i++) {
      final position = i * rate / 16000;
      final left = position.floor().clamp(0, frames - 1);
      final right = math.min(left + 1, frames - 1);
      final sample = samples[left] + (samples[right] - samples[left]) * (position - left);
      header.setInt16(44 + i * 2, sample.round().clamp(-32768, 32767), Endian.little);
    }
    if (output.length > 10 * 1024 * 1024) {
      throw const FormatException('Normalized recording exceeds 10 MiB');
    }
    await file.writeAsBytes(output, flush: true);
  }

  static String _tag(Uint8List bytes, int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));
  static void _writeTag(Uint8List bytes, int offset, String value) {
    bytes.setRange(offset, offset + 4, value.codeUnits);
  }
}
