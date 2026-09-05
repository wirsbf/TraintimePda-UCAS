import 'package:flutter/material.dart';

import '../data/settings_controller.dart';
import '../data/auth_gate.dart';
import '../data/ucas_client.dart';
import '../model/schedule.dart';
import '../model/exam.dart';
import 'schedule_grid.dart';
import '../util/schedule_utils.dart';
import '../data/cache_manager.dart';
import 'widget/bouncing_button.dart';

class SchedulePage extends StatefulWidget {
  final SettingsController settings;
  const SchedulePage({super.key, required this.settings});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  Schedule? _schedule;
  List<Exam>? _exams;
  List<Exam> _customExams = [];
  List<Course> _customCourses = [];
  String? _status;
  bool _loading = false;
  int _selectedWeek = 1;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _selectedWeek = widget.settings.currentWeek();
    widget.settings.addListener(_handleSettingsChange);

    // Initialize controllers with saved values
    _usernameController.text = widget.settings.username;
    _passwordController.text = widget.settings.password;

    _pageController = PageController(
      initialPage: _selectedWeek > 0 ? _selectedWeek - 1 : 0,
    );

    // Auto-refresh if credentials exist
    if (widget.settings.username.isNotEmpty &&
        widget.settings.password.isNotEmpty) {
      _fetchSchedule();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    widget.settings.removeListener(_handleSettingsChange);
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _handleSettingsChange() {
    final maxWeek = widget.settings.semesterLength;
    if (_selectedWeek > maxWeek) {
      if (mounted) {
        setState(() {
          _selectedWeek = maxWeek;
        });
      }
    }
    // Update PageController if _selectedWeek changes due to settings
    if (_pageController.hasClients &&
        _pageController.page?.round() != _selectedWeek - 1) {
      _pageController.jumpToPage(_selectedWeek - 1);
    }
  }

  Future<void> _showLoginDialog() async {
    // Refresh controllers from settings in case they changed in SettingsPage
    if (_usernameController.text.isEmpty) {
      _usernameController.text = widget.settings.username;
    }
    if (_passwordController.text.isEmpty) {
      _passwordController.text = widget.settings.password;
    }

    final formKey = GlobalKey<FormState>();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('登录拉取课程'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _usernameController,
                  decoration: const InputDecoration(labelText: '账号/邮箱'),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入账号' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _passwordController,
                  decoration: const InputDecoration(labelText: '密码'),
                  obscureText: true,
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入密码' : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  // Save credentials to settings
                  widget.settings.updateUsername(
                    _usernameController.text.trim(),
                  );
                  widget.settings.updatePassword(_passwordController.text);
                  Navigator.of(context).pop(true);
                }
              },
              child: const Text('登录'),
            ),
          ],
        );
      },
    );

    if (result == true) {
      await _fetchSchedule();
    }
  }

  Future<void> _fetchSchedule() async {
    if (_loading) {
      return;
    }
    setState(() {
      _loading = true;
      _status = '正在获取课程表...';
    });

    try {
      // 1. Fetch Schedule (uses cached session, auto-retry if expired)
      final schedule = await UcasClient.instance.fetchSchedule();
      if (mounted) {
        setState(() => _schedule = schedule);
        CacheManager().saveSchedule(schedule);
      }

      // 2. Fetch Exams (Optional but good to refresh)
      try {
        final exams = await UcasClient.instance.fetchExams();
        CacheManager().saveExams(exams);
        if (mounted) setState(() => _exams = exams);
      } catch (_) {}

      // 3. Refresh Custom (if needed)
      final custom = await CacheManager().getCustomCourses();
      final customExams = await CacheManager().getCustomExams();
      if (mounted) {
        setState(() {
          _customCourses = custom;
          _customExams = customExams;
        });
      }

      if (mounted) setState(() => _status = null);
    } on CaptchaRequiredException {
      // One coordinated captcha via the global gate; retry once on success.
      if (await AuthGate.instance.ensureLoggedIn()) {
        try {
          final schedule = await UcasClient.instance.fetchSchedule();
          if (mounted) {
            setState(() => _schedule = schedule);
            CacheManager().saveSchedule(schedule);
          }
        } catch (_) {}
      } else {
        if (mounted) setState(() => _status = '验证码已取消');
      }
    } catch (e) {
      if (mounted) setState(() => _status = '获取失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentWeek = widget.settings.currentWeek();

    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF6F8FC),
        surfaceTintColor: Colors.transparent,
        title: BouncingButton(
          onTap: () {
            if (_pageController.hasClients) {
              _pageController.jumpToPage(currentWeek - 1);
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'UCAS 课程表',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              Text(
                '第$_selectedWeek周 (本周: $currentWeek)${_status != null && (_status!.contains('已拉取') || _status!.contains('正在')) ? ' | $_status' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onPressed: _loading ? null : _showLoginDialog,
            tooltip: '拉取课表',
          ),
        ],
      ),
      body: Column(
        children: [
          _StatusBanner(status: _status),
          Expanded(
            child: PageView.builder(
              physics: const BouncingScrollPhysics(),
              controller: _pageController,
              itemCount: widget.settings.semesterLength,
              onPageChanged: (index) {
                setState(() {
                  _selectedWeek = index + 1;
                });
              },
              itemBuilder: (context, index) {
                final week = index + 1;
                final startOfWeek = widget.settings.termStartDate.add(
                  Duration(days: (week - 1) * 7),
                );

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
                // Add custom exams
                for (final e in _customExams) {
                  final c = examToCourse(
                    e,
                    widget.settings.termStartDate,
                    widget.settings.weekOffset,
                  );
                  if (c != null) allCourses.add(c);
                }
                allCourses.addAll(_customCourses);

                final filteredCourses = allCourses
                    .where((course) => courseMatchesWeek(course, week))
                    .toList();

                return Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE5EAF2)),
                  ),
                  child: filteredCourses.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                week == currentWeek ? '本周暂无课程' : '第$week周暂无课程',
                                style: const TextStyle(
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                              if (_schedule == null)
                                TextButton(
                                  onPressed: _showLoginDialog,
                                  child: const Text('点击登录拉取'),
                                ),
                            ],
                          ),
                        )
                      : ScheduleGrid(
                          courses: filteredCourses,
                          startOfWeek: startOfWeek,
                          onCourseTap: (course) =>
                              _showCourseDetailDialog(course),
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showCourseDetailDialog(Course course) {
    // Check if it's a custom course (Lecture)
    final isCustom = course.id.startsWith('L_');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(course.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('教室: ${course.classroom}'),
            if (course.teacher.isNotEmpty) Text('教师: ${course.teacher}'),
            Text(
              '时间: ${course.weekday} ${course.timeSlot.startTime}-${course.timeSlot.endTime}',
            ),
            if (course.weeks.isNotEmpty) Text('周次: ${course.weeks}'),
            if (course.notes.isNotEmpty) Text('备注: ${course.notes}'),
          ],
        ),
        actions: [
          if (isCustom)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () async {
                await CacheManager().removeCustomCourse(course.id);
                if (mounted) {
                  Navigator.pop(context); // Close dialog
                  _fetchSchedule(); // Refresh
                }
              },
              child: const Text('从课表中删除'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status});

  final String? status;

  @override
  Widget build(BuildContext context) {
    if (status == null ||
        status!.trim().isEmpty ||
        status!.contains('已拉取') ||
        status!.contains('正在')) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF2FF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        status!,
        style: const TextStyle(
          color: Color(0xFF1E40AF),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// Local methods removed, using schedule_utils.dart logic
