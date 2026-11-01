import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'imac_session.dart';
import 'tv_web_page.dart';

/// Nexus TV: only the TV remote from Nexus Remote, built with `--flavor tv -t lib/main_tv.dart`.
void main() => runApp(const NexusTvApp());

class NexusTvApp extends StatefulWidget {
  const NexusTvApp({super.key, this.session});
  final ImacSession? session;
  @override
  State<NexusTvApp> createState() => _NexusTvAppState();
}

class _NexusTvAppState extends State<NexusTvApp> {
  late final ImacSession session = widget.session ?? ImacSession();
  late final Future<void> ready = session.initialize();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus TV',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0E1116),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF8AE3CB), brightness: Brightness.dark),
      ),
      home: FutureBuilder<void>(
        future: ready,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          // There is no other page to go back to: leaving the TV page leaves the app
          return TvWebPage(session: session, onExit: SystemNavigator.pop);
        },
      ),
    );
  }
}
