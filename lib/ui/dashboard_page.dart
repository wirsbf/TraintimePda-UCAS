import 'package:flutter/material.dart';
import '../data/settings_controller.dart';
import '../ui/widget/bouncing_button.dart';
import '../data/ucas_client.dart';
import '../data/auth_gate.dart';
import '../model/schedule.dart';
import '../model/lecture.dart';
import '../model/exam.dart';
import '../model/sep_portal.dart';
import 'schedule_page.dart';
import 'lecture_page.dart';
import '../util/schedule_utils.dart';
import '../data/cache_manager.dart';
import 'lecture_detail_dialog.dart';
import '../data/services/update_service.dart';
import 'package:url_launcher/url_launcher.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.settings});

  final SettingsController settings;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Schedule? _schedule;
  List<Lecture>? _lectures;
  bool _loadingSchedule = false;
  bool _loadingLectures = false;
  bool _isScheduleRealtime = false;
  bool _isLecturesRealtime = false;
  List<Exam>? _exams;
  List<Course> _customCourses = [];
  String? _error;
  SepProfile? _profile;
  CreditProgress? _credit;
  List<SepReminder> _reminders = [];

  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    // Prioritize real-time data - fetch immediately
    // Cache is loaded as fallback only on fetch failure
    _fetchData();
    _checkUpdate();
    _animController.forward();
  }

  Future<void> _checkUpdate() async {
    try {
      // Small delay to let the UI settle
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      
      final info = await UpdateService().checkUpdate();
      if (!mounted || info == null || !info.hasUpdate) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('发现新版本'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('最新版本：v${info.version}'),
              const SizedBox(height: 8),
              const Text('更新内容：'),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Text(info.body),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('稍后'),
            ),
            TextButton(
              onPressed: () {
                launchUrl(Uri.parse(info.url));
                Navigator.pop(context);
              },
              child: const Text('下载更新'),
            ),
          ],
        ),
      );
    } catch (_) {
      // Silent failure for auto-check
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Throttled: window switches happen constantly; a full refetch
      // (and with it possible captcha prompts) at most every 5 minutes.
      _fetchDataThrottled();
    }
  }

  DateTime _lastAutoFetchAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _fetchDataThrottled() async {
    if (DateTime.now().difference(_lastAutoFetchAt) <
        const Duration(minutes: 5)) {
      return;
    }
    _lastAutoFetchAt = DateTime.now();
    await _fetchData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animController.dispose();
    super.dispose();
  }

  Future<void> _loadCache() async {
    final cachedSchedule = await CacheManager().getSchedule();
    if (mounted && cachedSchedule != null) {
      setState(() => _schedule = cachedSchedule);
    }

    final cachedLectures = await CacheManager().getLectures();
    if (mounted && cachedLectures.isNotEmpty) {
      _processLectures(cachedLectures);
    }

    final cachedExams = await CacheManager().getExams();
    final cachedCustom = await CacheManager().getCustomCourses();
    if (mounted) {
      setState(() {
        _exams = cachedExams;
        _customCourses = cachedCustom;
      });
    }
    _restorePortalCache();
  }

  /// SEP 门户卡片（一卡通 + 学分进度）。失败静默——卡片不显示而已。
  Future<void> _fetchPortalCards() async {
    try {
      final portal = UcasClient.instance.sepPortal;
      final profile = await portal.fetchProfile();
      final credit = await portal.fetchCreditProgress();
      List<SepReminder> reminders = const [];
      try {
        reminders = await portal.fetchReminders();
      } catch (_) {}
      if (mounted) setState(() => _reminders = reminders);
      if (mounted) {
        setState(() {
          _profile = profile;
          _credit = credit;
        });
      }
      CacheManager().savePortalData({
        'profile': {'name': profile.name, 'balance': profile.balance,
          'profession': profile.profession, 'teacher': profile.teacher},
        'credit': {'xslb': credit.category, 'req': credit.totalRequired,
          'got': credit.totalObtained, 'enrolled': credit.enrolled},
      });
    } catch (e) {
      debugPrint('Portal cards fetch failed: $e');
    }
  }

  void _restorePortalCache() {
    final cached = CacheManager().getPortalData();
    if (cached == null) return;
    final p = cached['profile'];
    final c = cached['credit'];
    if (p is Map<String, dynamic> && c is Map<String, dynamic>) {
      setState(() {
        _profile = SepProfile(
          name: '${p['name'] ?? ''}',
          balance: (p['balance'] as num?)?.toInt() ?? 0,
          profession: '${p['profession'] ?? ''}',
          teacher: '${p['teacher'] ?? ''}',
        );
        _credit = CreditProgress(
          category: '${c['xslb'] ?? ''}',
          totalRequired: '${c['req'] ?? ''}',
          totalObtained: '${c['got'] ?? ''}',
          enrolled: '${c['enrolled'] ?? ''}',
        );
      });
    }
  }

  Future<void> _fetchData({bool force = false}) async {
    // 1. Login via the global gate (single dialog + cooldowns).
    final loggedIn = await AuthGate.instance.ensureLoggedIn();
    if (!loggedIn) {
      debugPrint('[Dashboard] login unavailable (cancelled/cooldown); using cache');
      if (mounted) {
        setState(() {
          _loadingSchedule = false;
          _loadingLectures = false;
        });
      }
      return;
    }

    // 2. Check Cache
    if (!force) {
      final lastUpdate = await CacheManager().getLastUpdateTime();
      final now = DateTime.now().millisecondsSinceEpoch;
      // Reduce cache validity to 5 minutes to ensure fresh data on resume
      if (now - lastUpdate < 5 * 60 * 1000) {
        if (_schedule != null && _lectures != null) return;
      }
    }

    // 3. Fetch Data in Parallel
    await Future.wait([
      _fetchSchedule(),
      _fetchExams(),
      _fetchLectures(),
      _fetchPortalCards(),
    ]);

    // Refresh custom courses from cache (in case they changed elsewhere)
    final custom = await CacheManager().getCustomCourses();
    if (mounted) {
      setState(() => _customCourses = custom);
      _processWithAddedStatus();
    }

    await CacheManager().saveLastUpdateTime();
  }

  Future<void> _fetchExams() async {
    try {
      // Fetch exams using cached session (auto-retry if session expired)
      final exams = await UcasClient.instance.fetchExams();
      CacheManager().saveExams(exams);
      if (mounted) setState(() => _exams = exams);
    } catch (e) {
      debugPrint('Exam Fetch Error: $e - Loading from cache');
      // Fallback to cache on error
      final cachedExams = await CacheManager().getExams();
      if (mounted && cachedExams.isNotEmpty) {
        setState(() => _exams = cachedExams);
      }
    }
  }

  void _onRefresh() async {
    setState(() {
      _loadingSchedule = true;
      _loadingLectures = true;
    });

    // Force refresh means force fetch, but logic inside _fetchData(force: true) handles it.
    // But _onRefresh was calling _fetchSchedule directly.
    // Let's use _fetchData(force: true) for consistency or just call fetches?
    // User wants "Refresh" to always update.

    // Re-login just to be sure (though _fetchData does it, _onRefresh is manual).
    // Let's call _fetchData(force: true) to reuse logic?
    // But _fetchData reloads cache first which causes flicker maybe?
    // No, _fetchData sets state.
    // Let's keep _onRefresh explicit but reuse login if possible.

    // Actually simpler:
    await _fetchData(force: true);
  }

  Future<void> _fetchSchedule() async {
    setState(() => _loadingSchedule = true);
    try {
      // Fetch schedule using cached session (auto-retry if session expired)
      final schedule = await UcasClient.instance.fetchSchedule();
      if (mounted) {
        setState(() {
          _schedule = schedule;
          _isScheduleRealtime = true;
        });
        CacheManager().saveSchedule(schedule);
      }
    } on CaptchaRequiredException {
      // One coordinated captcha via the global gate; retry once on success.
      if (await AuthGate.instance.ensureLoggedIn()) {
        try {
          final schedule = await UcasClient.instance.fetchSchedule();
          if (mounted) {
            setState(() {
              _schedule = schedule;
              _isScheduleRealtime = true;
            });
            CacheManager().saveSchedule(schedule);
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Schedule Fetch Error: $e - Loading from cache');
      // Fallback to cache on error
      final cachedSchedule = await CacheManager().getSchedule();
      if (mounted && cachedSchedule != null) {
        setState(() => _schedule = cachedSchedule);
      }
    } finally {
      if (mounted) setState(() => _loadingSchedule = false);
    }
  }

  Future<void> _fetchLectures() async {
    setState(() => _loadingLectures = true);
    try {
      // Fetch lectures using cached session (auto-retry if session expired)
      final lectures = await UcasClient.instance.fetchLectures();

      // Filter >= Today
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      final filtered = lectures.where((l) {
        if (l.date.isEmpty) return true;
        final d = DateTime.tryParse(l.date);
        if (d != null) {
          final lectureDate = DateTime(d.year, d.month, d.day);
          return !lectureDate.isBefore(today);
        }
        return true;
      }).toList();
      filtered.sort((a, b) => a.date.compareTo(b.date));

      if (mounted) {
        _processLectures(filtered);
        setState(() => _isLecturesRealtime = true);
        // Only save to cache if we actually got lectures
        // or if we're sure it's an empty list but a successful fetch
        if (lectures.isNotEmpty) {
          CacheManager().saveLectures(lectures);
        }
      }
    } on CaptchaRequiredException {
      // One coordinated captcha via the global gate; retry once on success.
      if (await AuthGate.instance.ensureLoggedIn()) {
        try {
          await UcasClient.instance.fetchLectures();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Lecture Fetch Error: $e - Loading from cache');
      // Fallback to cache on error
      final cachedLectures = await CacheManager().getLectures();
      if (mounted && cachedLectures.isNotEmpty) {
        _processLectures(cachedLectures);
      }
    } finally {
      if (mounted) setState(() => _loadingLectures = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('首页'), centerTitle: false),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildAnimatedItem(
              0,
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Text(
                        '今日课程',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      _buildStatusBadge(_isScheduleRealtime, _loadingSchedule),
                    ],
                  ),
                  IconButton(
                    onPressed: _onRefresh,
                    icon: const Icon(Icons.refresh, color: Colors.blue),
                    tooltip: '刷新',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _buildAnimatedItem(
              1,
              BouncingButton(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SchedulePage(settings: widget.settings),
                    ),
                  );
                },
                child: _buildTodayCourses(),
              ),
            ),
            const SizedBox(height: 12),
            _buildAnimatedItem(2, _buildPortalCards()),
            if (_reminders.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildAnimatedItem(3, _buildReminderBanner()),
            ],
            const SizedBox(height: 24),
            _buildAnimatedItem(
              3,
              BouncingButton(
                // Make entire header clickable
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LecturePage(settings: widget.settings),
                    ),
                  ).then((_) async {
                    // Refresh custom courses on return
                    final custom = await CacheManager().getCustomCourses();
                    if (mounted) {
                      setState(() => _customCourses = custom);
                      _processWithAddedStatus();
                    }
                  });
                },
                child: _buildSectionHeader(
                  '近期讲座',
                  isRealtime: _isLecturesRealtime,
                  isLoading: _loadingLectures,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildAnimatedItem(5, _buildLecturesList()),
          ],
        ),
      ),
    );
  }

  /// 校园卡 + 学业进度（SEP 门户数据）
  Widget _buildPortalCards() {
    if (_profile == null && _credit == null) return const SizedBox.shrink();

    return Row(
      children: [
        if (_profile != null)
          Expanded(
            child: _portalCard(
              icon: Icons.account_balance_wallet,
              iconColor: const Color(0xFF10B981),
              title: '校园卡',
              main: '¥${_profile!.balance}',
              sub: _profile!.teacher.isEmpty
                  ? _profile!.name
                  : '${_profile!.name} · 导师 ${_profile!.teacher}',
            ),
          ),
        if (_profile != null && _credit != null) const SizedBox(width: 12),
        if (_credit != null)
          Expanded(
            child: _portalCard(
              icon: Icons.school,
              iconColor: const Color(0xFF6366F1),
              title: '学业 · ${_credit!.category}',
              main: '${_credit!.totalObtained}/${_credit!.totalRequired} 学分',
              sub: _credit!.enrolled.isNotEmpty && _credit!.enrolled != _credit!.totalObtained
                  ? '在读 ${_credit!.enrolled} 学分'
                  : (_credit!.progress >= 1 ? '已达标 🎉' : '进行中'),
              progress: _credit!.progress,
            ),
          ),
      ],
    );
  }

  Widget _portalCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String main,
    required String sub,
    double? progress,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(main,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          if (progress != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: Colors.grey[200],
                color: iconColor,
              ),
            ),
          if (progress != null) const SizedBox(height: 4),
          Text(sub, style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  /// 作业督促通知等提醒横幅（SEP reminderPage）
  Widget _buildReminderBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in _reminders.take(3))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  const Icon(Icons.notifications_active,
                      size: 16, color: Color(0xFFEA580C)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(r.title,
                        style: const TextStyle(fontSize: 13),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Text(r.time.split(' ').first,
                      style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, {bool isRealtime = false, bool isLoading = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            _buildStatusBadge(isRealtime, isLoading),
          ],
        ),
        const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
      ],
    );
  }

  Widget _buildStatusBadge(bool isRealtime, bool isLoading) {
    if (isLoading) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isRealtime ? Colors.green.shade50 : Colors.orange.shade50,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: isRealtime ? Colors.green.shade200 : Colors.orange.shade200,
        ),
      ),
      child: Text(
        isRealtime ? '实时' : '缓存',
        style: TextStyle(
          fontSize: 10,
          color: isRealtime ? Colors.green.shade700 : Colors.orange.shade700,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildTodayCourses() {
    // Only show full-screen loader if we have NO data at all
    if (_loadingSchedule && _schedule == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_schedule == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(child: Text('暂无课程数据，请点击“更多”去拉取')),
      );
    }

    // Filter courses for today
    final now = DateTime.now();
    final currentWeek = widget.settings.currentWeek();
    final weekday = now.weekday;

    final allCourses = <Course>[];
    if (_schedule != null) allCourses.addAll(_schedule!.courses);
    if (_exams != null) {
      for (final e in _exams!) {
        final c = examToCourse(
          e,
          widget.settings.termStartDate,
          widget.settings.weekOffset,
        );
        if (c != null) allCourses.add(c);
      }
    }
    allCourses.addAll(_customCourses);

    final todayCourses = allCourses.where((c) {
      // Check week
      if (!courseMatchesWeek(c, currentWeek)) return false;
      // Check day (Course.day returns int)
      return c.day == weekday;
    }).toList();

    // Sort by session start (Safe Int Comparison)
    todayCourses.sort((a, b) {
      final startA = _parseTimeInt(a.timeSlot.startTime);
      final startB = _parseTimeInt(b.timeSlot.startTime);
      return startA.compareTo(startB);
    });

    if (todayCourses.isEmpty) {
      return BouncingButton(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SchedulePage(settings: widget.settings),
            ),
          );
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.green.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Icon(Icons.weekend, size: 40, color: Colors.green.shade300),
              const SizedBox(height: 8),
              Text(
                '今天没有课哦，好好休息吧~',
                style: TextStyle(color: Colors.green.shade700),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: todayCourses.map((course) {
        return BouncingButton(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => SchedulePage(settings: widget.settings),
              ),
            ).then((_) async {
              final cached = await CacheManager().getSchedule();
              if (cached != null) setState(() => _schedule = cached);
            });
          },
          child: Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _getColor(course.name),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.class_,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          course.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(
                              Icons.access_time,
                              size: 14,
                              color: Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            Builder(
                              builder: (context) {
                                if (course.displayTime.isNotEmpty) {
                                  return Text(
                                    course.displayTime,
                                    style: const TextStyle(
                                      color: Colors.blue,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  );
                                }
                                int? start = int.tryParse(
                                  course.timeSlot.startTime.replaceAll(
                                    RegExp(r'[^0-9]'),
                                    '',
                                  ),
                                );
                                int? end = int.tryParse(
                                  course.timeSlot.endTime.replaceAll(
                                    RegExp(r'[^0-9]'),
                                    '',
                                  ),
                                );
                                String timeStr =
                                    '${course.timeSlot.startTime}-${course.timeSlot.endTime}';
                                if (start != null && end != null) {
                                  String realTime = getTimeStringFromSection(
                                    start,
                                    end,
                                  );
                                  if (realTime.isNotEmpty) timeStr = realTime;
                                }
                                return Text(
                                  timeStr,
                                  style: const TextStyle(
                                    color: Colors.blue,
                                    fontWeight: FontWeight.bold,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(
                              Icons.location_on,
                              size: 14,
                              color: Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                course.classroom,
                                style: const TextStyle(color: Colors.grey),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Color _getColor(String name) {
    final colors = [
      Colors.blue,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.red,
      Colors.indigo,
    ];
    return colors[name.hashCode.abs() % colors.length];
  }

  Widget _buildLecturesList() {
    // Only show loader if we have NO data
    if (_loadingLectures && (_lectures == null || _lectures!.isEmpty)) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_lectures == null || _lectures!.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(child: Text('近期暂无讲座')),
      );
    }

    // Take top 3
    final display = _lectures!.take(3).toList();

    return Column(
      children: display.map((lecture) {
        return BouncingButton(
          onTap: () {
            showDialog(
              context: context,
              builder: (context) => LectureDetailDialog(
                lecture: lecture,
                settings: widget.settings,
              ),
            ).then((_) async {
              // Refresh custom courses and re-sort
              final custom = await CacheManager().getCustomCourses();
              if (mounted) {
                setState(() => _customCourses = custom);
                _processWithAddedStatus();
              }
            });
          },
          child: Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          lecture.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(
                              Icons.person,
                              size: 14,
                              color: Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                lecture.speaker,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${lecture.date} ${lecture.time.contains(' ') ? lecture.time.split(' ').last : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_customCourses.any((c) => c.id == 'L_${lecture.id}'))
                    Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: const Text(
                        '已添加',
                        style: TextStyle(fontSize: 10, color: Colors.blue),
                      ),
                    )
                  else
                    const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // Copied helper from schedule_page or use util
  // bool _courseMatchesWeek(Course course, int week) { ... } // Removed

  void _processLectures(List<Lecture> list) {
    // Re-filter just in case (e.g. cache loaded)
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
    filtered.sort((a, b) => a.date.compareTo(b.date));
    setState(() => _lectures = filtered);
    _processWithAddedStatus();
  }

  void _processWithAddedStatus() {
    if (_lectures == null) return;
    // Get Added IDs from custom courses
    final addedIds = _customCourses
        .where((c) => c.id.startsWith('L_'))
        .map((c) => c.id.substring(2))
        .toSet();

    _lectures!.sort((a, b) {
      final aAdded = addedIds.contains(a.id);
      final bAdded = addedIds.contains(b.id);
      if (aAdded && !bAdded) return -1;
      if (!aAdded && bAdded) return 1;
      return a.date.compareTo(b.date);
    });
    // Force rebuild if this runs after set state
  }

  int _parseTimeInt(String timeStr) {
    final clean = timeStr.replaceAll(RegExp(r'[^0-9:]'), '');
    if (clean.contains(':')) {
      final parts = clean.split(':');
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      return h * 60 + m;
    }
    return int.tryParse(clean) ?? 0;
  }

  Widget _buildAnimatedItem(int index, Widget child) {
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 0.1), end: Offset.zero)
          .animate(
            CurvedAnimation(
              parent: _animController,
              curve: Interval(index * 0.2, 1.0, curve: Curves.easeOutQuad),
            ),
          ),
      child: FadeTransition(
        opacity: Tween<double>(begin: 0, end: 1).animate(
          CurvedAnimation(
            parent: _animController,
            curve: Interval(index * 0.2, 1.0, curve: Curves.easeOutQuad),
          ),
        ),
        child: child,
      ),
    );
  }
}
