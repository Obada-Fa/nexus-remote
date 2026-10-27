import 'package:flutter/material.dart';
import 'app_icon.dart';
import 'session.dart';

class OpenAppsBar extends StatelessWidget {
  const OpenAppsBar({super.key, required this.session});

  final RemoteSession session;

  void _showWindowMenu(BuildContext context, DesktopWindow window) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161C24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: AppIconTile(icon: window.icon, name: window.appName, size: 36),
                  title: Text(window.appName, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    window.title.isEmpty ? window.appName : window.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.open_in_new, color: Color(0xFF8AE3CB)),
                  title: const Text('Bring to Front (Focus)'),
                  onTap: () {
                    Navigator.pop(context);
                    session.activateWindow(window.id);
                  },
                ),
                ListTile(
                  leading: Icon(
                    window.isMaximized ? Icons.filter_none : Icons.crop_square,
                    color: Colors.white70,
                  ),
                  title: Text(window.isMaximized ? 'Restore' : 'Maximize'),
                  onTap: () {
                    Navigator.pop(context);
                    session.maximizeWindow(window.id);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.remove, color: Colors.white70),
                  title: const Text('Minimize'),
                  onTap: () {
                    Navigator.pop(context);
                    session.minimizeWindow(window.id);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.close, color: Color(0xFFFF8080)),
                  title: const Text('Close Window', style: TextStyle(color: Color(0xFFFF8080))),
                  onTap: () {
                    Navigator.pop(context);
                    session.closeWindow(window.id);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openStartMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161C24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => StartMenuSheet(session: session),
    );
  }

  @override
  Widget build(BuildContext context) {
    final windows = session.openWindows;

    return Container(
      height: 58,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF141920),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF26303D)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Start / Dash Button (Zorin Dash / Windows Start Menu style)
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _openStartMenu(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF8AE3CB).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF8AE3CB).withValues(alpha: 0.35)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.grid_view_rounded, size: 20, color: Color(0xFF8AE3CB)),
                    SizedBox(width: 4),
                    Text(
                      'Dash',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF8AE3CB),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          const VerticalDivider(width: 1, indent: 8, endIndent: 8, color: Color(0xFF26303D)),
          const SizedBox(width: 6),

          // Scrollable Open Apps Row
          Expanded(
            child: windows.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        'No open windows',
                        style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.4)),
                      ),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: windows.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 4),
                    itemBuilder: (context, index) {
                      final w = windows[index];
                      final isActive = w.isActive;
                      final isMinimized = w.isMinimized;

                      return Tooltip(
                        message: '${w.appName} — ${w.title}',
                        triggerMode: TooltipTriggerMode.longPress,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              if (isActive) {
                                // Acting like Zorin / Windows taskbar: clicking active window minimizes it!
                                session.minimizeWindow(w.id);
                              } else {
                                // Clicking inactive window activates / focuses it
                                session.activateWindow(w.id);
                              }
                            },
                            onLongPress: () => _showWindowMenu(context, w),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isActive
                                    ? const Color(0xFF8AE3CB).withValues(alpha: 0.18)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                                border: isActive
                                    ? Border.all(color: const Color(0xFF8AE3CB).withValues(alpha: 0.5))
                                    : Border.all(color: Colors.transparent),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Opacity(
                                    opacity: isMinimized ? 0.55 : 1.0,
                                    child: AppIconTile(icon: w.icon, name: w.appName, size: 28),
                                  ),
                                  const SizedBox(height: 3),
                                  // Active / Running Indicator
                                  Container(
                                    width: isActive ? 16 : 5,
                                    height: 3,
                                    decoration: BoxDecoration(
                                      color: isActive
                                          ? const Color(0xFF8AE3CB)
                                          : isMinimized
                                              ? Colors.white24
                                              : const Color(0xFF8AE3CB).withValues(alpha: 0.6),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),

          const SizedBox(width: 4),
          const VerticalDivider(width: 1, indent: 8, endIndent: 8, color: Color(0xFF26303D)),

          // Show Desktop button (Windows / Zorin style)
          IconButton(
            icon: const Icon(Icons.desktop_windows_outlined, size: 18),
            tooltip: 'Show Desktop',
            visualDensity: VisualDensity.compact,
            onPressed: session.showDesktop,
          ),
        ],
      ),
    );
  }
}

class StartMenuSheet extends StatefulWidget {
  const StartMenuSheet({super.key, required this.session});

  final RemoteSession session;

  @override
  State<StartMenuSheet> createState() => _StartMenuSheetState();
}

class _StartMenuSheetState extends State<StartMenuSheet> {
  String _search = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.session.refreshWindows();
    widget.session.refreshApps();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.trim().toLowerCase();
    final windows = widget.session.openWindows.where((w) {
      if (query.isEmpty) return true;
      return w.appName.toLowerCase().contains(query) || w.title.toLowerCase().contains(query);
    }).toList();

    final apps = widget.session.installedApps.where((a) {
      if (query.isEmpty) return true;
      return a.name.toLowerCase().contains(query) || a.id.toLowerCase().contains(query);
    }).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Search Bar
              TextField(
                controller: _searchController,
                onChanged: (val) => setState(() => _search = val),
                decoration: InputDecoration(
                  hintText: 'Search windows & apps…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _search.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _search = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: const Color(0xFF1E2530),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Content Area
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [
                    // Section: Open Windows
                    Row(
                      children: [
                        const Icon(Icons.web_stories, size: 16, color: Color(0xFF8AE3CB)),
                        const SizedBox(width: 8),
                        Text(
                          'OPEN WINDOWS (${windows.length})',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () {
                            widget.session.showDesktop();
                            Navigator.pop(context);
                          },
                          icon: const Icon(Icons.desktop_windows, size: 14),
                          label: const Text('Show Desktop', style: TextStyle(fontSize: 11)),
                          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    if (windows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          query.isEmpty ? 'No open windows on your PC.' : 'No matching windows found.',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 13),
                        ),
                      )
                    else
                      ...windows.map((w) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: w.isActive
                                ? const Color(0xFF8AE3CB).withValues(alpha: 0.12)
                                : const Color(0xFF1E2530),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: w.isActive
                                  ? const Color(0xFF8AE3CB).withValues(alpha: 0.4)
                                  : const Color(0xFF2D3948),
                            ),
                          ),
                          child: Row(
                            children: [
                              AppIconTile(icon: w.icon, name: w.appName, size: 36),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          w.appName,
                                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                        ),
                                        if (w.isActive) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF8AE3CB),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: const Text(
                                              'ACTIVE',
                                              style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.black,
                                              ),
                                            ),
                                          ),
                                        ],
                                        if (w.isMinimized) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: Colors.white24,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: const Text(
                                              'MINIMIZED',
                                              style: TextStyle(fontSize: 9, color: Colors.white70),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      w.title.isEmpty ? w.appName : w.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.white.withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Quick Window Action Controls (Focus, Maximize, Minimize, Close)
                              IconButton(
                                icon: const Icon(Icons.open_in_new, size: 18),
                                tooltip: 'Focus / Bring to front',
                                visualDensity: VisualDensity.compact,
                                onPressed: () {
                                  widget.session.activateWindow(w.id);
                                  Navigator.pop(context);
                                },
                              ),
                              IconButton(
                                icon: Icon(
                                  w.isMaximized ? Icons.filter_none : Icons.crop_square,
                                  size: 18,
                                ),
                                tooltip: w.isMaximized ? 'Restore' : 'Maximize',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => widget.session.maximizeWindow(w.id),
                              ),
                              IconButton(
                                icon: const Icon(Icons.remove, size: 18),
                                tooltip: 'Minimize',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => widget.session.minimizeWindow(w.id),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 18, color: Color(0xFFFF8080)),
                                tooltip: 'Close',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => widget.session.closeWindow(w.id),
                              ),
                            ],
                          ),
                        );
                      }),

                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 8),

                    // Section: Applications (Launcher)
                    Row(
                      children: [
                        const Icon(Icons.apps, size: 16, color: Color(0xFF8AE3CB)),
                        const SizedBox(width: 8),
                        Text(
                          'APPLICATIONS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    if (apps.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'No applications found.',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 13),
                        ),
                      )
                    else
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 80,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 8,
                          childAspectRatio: 0.8,
                        ),
                        itemCount: apps.length,
                        itemBuilder: (context, i) {
                          final a = apps[i];
                          final isRunning = windows.any((w) =>
                              w.wmClass.toLowerCase().contains(a.id.toLowerCase()) ||
                              w.appName.toLowerCase() == a.name.toLowerCase());

                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              widget.session.launchApp(a.id, a.exec);
                              Navigator.pop(context);
                            },
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    AppIconTile(icon: a.icon, name: a.name, size: 40),
                                    if (isRunning)
                                      Positioned(
                                        bottom: -2,
                                        left: 0,
                                        right: 0,
                                        child: Center(
                                          child: Container(
                                            width: 6,
                                            height: 6,
                                            decoration: const BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: Color(0xFF8AE3CB),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  a.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withValues(alpha: 0.8),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
