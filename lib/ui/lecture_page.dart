import 'package:flutter/material.dart';
import '../data/settings_controller.dart';
import '../data/auth_gate.dart';
import '../data/ucas_client.dart';
import '../model/lecture.dart';
import 'lecture_detail_dialog.dart';
import '../data/cache_manager.dart';
import 'widget/bouncing_button.dart';

class LecturePage extends StatefulWidget {
  final SettingsController settings;
  const LecturePage({super.key, required this.settings});

  @override
  State<LecturePage> createState() => _LecturePageState();
}

class _LecturePageState extends State<LecturePage> {
  Set<String> _addedIds = {};
  List<Lecture>? _lectures;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCache();
    // Also fetch custom courses to know what's added
    _refreshAddedStatus();
    _fetchLectures();
  }

  Future<void> _refreshAddedStatus() async {
    final custom = await CacheManager().getCustomCourses();
    if (mounted) {
      setState(() {
        _addedIds = custom
            .where((c) => c.id.startsWith('L_'))
            .map((c) => c.id.substring(2)) // Remove L_
            .toSet();
      });
    }
  }

  Future<void> _loadCache() async {
    await _refreshAddedStatus();
    final cached = await CacheManager().getLectures();
    if (mounted && cached.isNotEmpty) {
      _processLectures(cached);
    }
  }

  void _processLectures(List<Lecture> list) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final filtered = list.where((l) {
      if (l.date.isEmpty) return true;
      final d = DateTime.tryParse(l.date);
      if (d != null) {
        final lectureDate = DateTime(d.year, d.month, d.day);
        return !lectureDate.isBefore(today);
      }
      return true;
    }).toList();

    _sortLectures(filtered);

    if (mounted) setState(() => _lectures = filtered);
  }

  void _sortLectures(List<Lecture> list) {
    list.sort((a, b) {
      final aAdded = _addedIds.contains(a.id);
      final bAdded = _addedIds.contains(b.id);
      if (aAdded && !bAdded) return -1;
      if (!aAdded && bAdded) return 1;
      return a.date.compareTo(b.date);
    });
  }

  Future<void> _fetchLectures() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Refresh added status first
      await _refreshAddedStatus();

      // Fetch lectures using cached session (auto-retry if session expired)
      final lectures = await UcasClient.instance.fetchLectures();

      // Filter for future lectures
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      final filtered = lectures.where((l) {
        if (l.date.isEmpty) return true; // Keep if unknown date
        final d = DateTime.tryParse(l.date);
        if (d != null) {
          final lectureDate = DateTime(d.year, d.month, d.day);
          return !lectureDate.isBefore(today);
        }
        return true;
      }).toList();

      _sortLectures(filtered);

      if (mounted) {
        setState(() {
          _lectures = filtered;
        });
      }
    } on CaptchaRequiredException {
      // One coordinated captcha via the global gate; retry once.
      if (await AuthGate.instance.ensureLoggedIn()) {
        try {
          final lectures = await UcasClient.instance.fetchLectures();
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final filtered = lectures.where((l) {
            if (l.date.isEmpty) return true;
            final d = DateTime.tryParse(l.date);
            return d == null || !DateTime(d.year, d.month, d.day).isBefore(today);
          }).toList();
          _sortLectures(filtered);
          if (mounted) setState(() => _lectures = filtered);
        } catch (_) {}
      } else if (mounted) {
        setState(() { _error = '验证码已取消'; });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('近期讲座'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _fetchLectures,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _fetchLectures, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_lectures == null || _lectures!.isEmpty) {
      return const Center(child: Text('近期暂无讲座'));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _lectures!.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final isAdded = _addedIds.contains(_lectures![index].id);
        return _LectureCard(
          lecture: _lectures![index],
          settings: widget.settings,
          isAdded: isAdded,
          onStatusChanged: _refreshAddedStatus,
        );
      },
    );
  }
}

class _LectureCard extends StatelessWidget {
  const _LectureCard({
    required this.lecture,
    required this.settings,
    this.isAdded = false,
    this.onStatusChanged,
  });

  final Lecture lecture;
  final SettingsController settings;
  final bool isAdded;
  final VoidCallback? onStatusChanged;

  @override
  Widget build(BuildContext context) {
    return BouncingButton(
      onTap: () {
        showDialog(
          context: context,
          builder: (context) =>
              LectureDetailDialog(lecture: lecture, settings: settings),
        ).then((_) => onStatusChanged?.call());
      },
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: isAdded
              ? BorderSide(color: Colors.blue.withOpacity(0.5), width: 1.5)
              : BorderSide.none,
        ),
        color: isAdded ? Colors.blue.shade50.withOpacity(0.3) : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      lecture.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (isAdded)
                    Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '已添加',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.blue.shade800,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.person, size: 16, color: Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      lecture.speaker,
                      style: const TextStyle(color: Colors.grey),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.access_time, size: 16, color: Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      lecture.time,
                      style: const TextStyle(color: Colors.grey),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Location Row Removed as per request (v9)
            ],
          ),
        ),
      ),
    );
  }
}

