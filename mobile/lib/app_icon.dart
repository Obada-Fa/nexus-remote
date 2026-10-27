import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';

final _iconBytesCache = <String, Uint8List>{};

class AppIconTile extends StatelessWidget {
  const AppIconTile({
    super.key,
    this.icon,
    required this.name,
    this.size = 36,
  });

  final String? icon;
  final String name;
  final double size;

  Uint8List? _decodeBytes(String uri) {
    final cached = _iconBytesCache[uri];
    if (cached != null) return cached;

    final match = RegExp(
      r'^data:image/(png|jpeg|jpg|webp|gif|bmp);base64,(.*)$',
      caseSensitive: false,
    ).firstMatch(uri);
    if (match == null) return null;
    try {
      final bytes = base64Decode(match.group(2)!);
      if (_iconBytesCache.length > 300) {
        _iconBytesCache.clear();
      }
      _iconBytesCache[uri] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = icon == null ? null : _decodeBytes(icon!);
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _monogram(),
        ),
      );
    }
    return _monogram();
  }

  Widget _monogram() {
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final hue = (name.isEmpty ? 0 : name.codeUnitAt(0) * 47) % 360;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue.toDouble(), 0.45, 0.45).toColor(),
            HSLColor.fromAHSL(1, ((hue + 40) % 360).toDouble(), 0.5, 0.28).toColor(),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          fontSize: size * 0.45,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}
