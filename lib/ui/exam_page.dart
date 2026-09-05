import 'package:flutter/material.dart';
import '../data/ucas_client.dart';
import '../model/exam.dart';
import '../data/cache_manager.dart';
import '../data/auth_gate.dart';

class ExamPage extends StatefulWidget {
  const ExamPage({super.key});

  @override
  State<ExamPage> createState() => _ExamPageState();
}

class _ExamPageState extends State<ExamPage> {
  List<Exam>? _fetchedExams;
  List<Exam> _customExams = [];
  bool _loading = false;
  String? _error;

  List<Exam> get _allExams {
    final all = <Exam>[];
    if (_fetchedExams != null) all.addAll(_fetchedExams!);
    all.addAll(_customExams);
    return all;
  }

  @override
  void initState() {
    super.initState();
    _loadCache();
    _fetchExams();
  }

  Future<void> _loadCache() async {
    final cached = await CacheManager().getExams();
    final customCached = await CacheManager().getCustomExams();
    if (mounted) {
      setState(() {
        if (cached.isNotEmpty) _fetchedExams = cached;
        _customExams = customCached;
      });
    }
  }

  Future<void> _fetchExams() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Fetch exams using cached session (auto-retry if session expired)
      final exams = await UcasClient.instance.fetchExams();

      // Sort exams: Future > Past > TBD
      // Within group: Date Ascending
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      exams.sort((a, b) {
        // Helper to get status
        // 0: Future (Not started or Today)
        // 1: Past (Finished)
        // 2: TBD

        int getStatus(Exam e) {
          if (e.time == '未安排' ||
              e.time == '无考试信息' ||
              e.time == '获取失败' ||
              e.date.isEmpty) {
            return 2;
          }
          final d = DateTime.tryParse(e.date);
          if (d == null) return 2;
          final eDate = DateTime(d.year, d.month, d.day);

          if (eDate.isBefore(today)) return 1; // Past
          return 0; // Future (Today is considered Future/Active)
        }

        final statusA = getStatus(a);
        final statusB = getStatus(b);

        if (statusA != statusB) return statusA.compareTo(statusB);

        // Secondary sort: Date Ascending
        return a.date.compareTo(b.date);
      });

      setState(() {
        _fetchedExams = exams;
      });
      await CacheManager().saveExams(exams);
    } on CaptchaRequiredException {
      // One coordinated captcha via the global gate; retry once.
      if (await AuthGate.instance.ensureLoggedIn()) {
        try {
          final exams = await UcasClient.instance.fetchExams();
          if (mounted) setState(() => _fetchedExams = exams);
          await CacheManager().saveExams(exams);
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
        title: const Text('考试安排'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showAddExamDialog,
            tooltip: '手动添加考试',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _fetchExams,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Future<void> _showAddExamDialog() async {
    final courseNameController = TextEditingController();
    final locationController = TextEditingController();
    final seatController = TextEditingController();
    DateTime selectedDate = DateTime.now();
    TimeOfDay startTime = const TimeOfDay(hour: 9, minute: 0);
    TimeOfDay endTime = const TimeOfDay(hour: 11, minute: 0);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('手动添加考试'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: courseNameController,
                      decoration: const InputDecoration(
                        labelText: '课程名称 *',
                        hintText: '请输入课程名称',
                      ),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('考试日期'),
                      subtitle: Text(
                        '${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}',
                      ),
                      trailing: const Icon(Icons.calendar_today),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: selectedDate,
                          firstDate: DateTime.now().subtract(
                            const Duration(days: 30),
                          ),
                          lastDate: DateTime.now().add(
                            const Duration(days: 365),
                          ),
                        );
                        if (picked != null) {
                          setDialogState(() => selectedDate = picked);
                        }
                      },
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('开始时间'),
                            subtitle: Text(startTime.format(context)),
                            onTap: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: startTime,
                              );
                              if (picked != null) {
                                setDialogState(() => startTime = picked);
                              }
                            },
                          ),
                        ),
                        Expanded(
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('结束时间'),
                            subtitle: Text(endTime.format(context)),
                            onTap: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: endTime,
                              );
                              if (picked != null) {
                                setDialogState(() => endTime = picked);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: locationController,
                      decoration: const InputDecoration(
                        labelText: '考试地点',
                        hintText: '如：教学楼 101',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: seatController,
                      decoration: const InputDecoration(
                        labelText: '座位号',
                        hintText: '如：25',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (courseNameController.text.trim().isEmpty) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('请输入课程名称')));
                      return;
                    }
                    Navigator.pop(context, true);
                  },
                  child: const Text('添加'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true) {
      final dateStr =
          '${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}';
      final timeStr =
          '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}-${endTime.hour.toString().padLeft(2, '0')}:${endTime.minute.toString().padLeft(2, '0')}';

      final exam = Exam(
        courseName: courseNameController.text.trim(),
        date: dateStr,
        time: timeStr,
        location: locationController.text.trim().isEmpty
            ? '未指定'
            : locationController.text.trim(),
        seat: seatController.text.trim(),
      );

      await CacheManager().addCustomExam(exam);
      setState(() {
        _customExams.add(exam);
      });
    }
  }

  Future<void> _showEditExamDialog(Exam exam) async {
    final courseNameController = TextEditingController(text: exam.courseName);
    final locationController = TextEditingController(
      text: exam.location == '未指定' ? '' : exam.location,
    );
    final seatController = TextEditingController(text: exam.seat);

    // Parse existing date
    DateTime selectedDate = DateTime.now();
    if (exam.date.isNotEmpty) {
      final parsed = DateTime.tryParse(exam.date);
      if (parsed != null) selectedDate = parsed;
    }

    // Parse existing time
    TimeOfDay startTime = const TimeOfDay(hour: 9, minute: 0);
    TimeOfDay endTime = const TimeOfDay(hour: 11, minute: 0);
    if (exam.time.isNotEmpty && exam.time.contains('-')) {
      final parts = exam.time.split('-');
      if (parts.length == 2) {
        final startParts = parts[0].split(':');
        final endParts = parts[1].split(':');
        if (startParts.length == 2 && endParts.length == 2) {
          startTime = TimeOfDay(
            hour: int.tryParse(startParts[0]) ?? 9,
            minute: int.tryParse(startParts[1]) ?? 0,
          );
          endTime = TimeOfDay(
            hour: int.tryParse(endParts[0]) ?? 11,
            minute: int.tryParse(endParts[1]) ?? 0,
          );
        }
      }
    }

    final oldCourseName = exam.courseName;
    final oldDate = exam.date;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('编辑考试'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: courseNameController,
                      decoration: const InputDecoration(
                        labelText: '课程名称 *',
                        hintText: '如：高等数学',
                      ),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('考试日期'),
                      subtitle: Text(
                        '${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}',
                      ),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: selectedDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2030),
                        );
                        if (picked != null) {
                          setDialogState(() => selectedDate = picked);
                        }
                      },
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('开始时间'),
                            subtitle: Text(startTime.format(context)),
                            onTap: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: startTime,
                              );
                              if (picked != null) {
                                setDialogState(() => startTime = picked);
                              }
                            },
                          ),
                        ),
                        Expanded(
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('结束时间'),
                            subtitle: Text(endTime.format(context)),
                            onTap: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: endTime,
                              );
                              if (picked != null) {
                                setDialogState(() => endTime = picked);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: locationController,
                      decoration: const InputDecoration(
                        labelText: '考试地点',
                        hintText: '如：教学楼 101',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: seatController,
                      decoration: const InputDecoration(
                        labelText: '座位号',
                        hintText: '如：25',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (courseNameController.text.trim().isEmpty) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('请输入课程名称')));
                      return;
                    }
                    Navigator.pop(context, true);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true) {
      final dateStr =
          '${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}';
      final timeStr =
          '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}-${endTime.hour.toString().padLeft(2, '0')}:${endTime.minute.toString().padLeft(2, '0')}';

      final newExam = Exam(
        courseName: courseNameController.text.trim(),
        date: dateStr,
        time: timeStr,
        location: locationController.text.trim().isEmpty
            ? '未指定'
            : locationController.text.trim(),
        seat: seatController.text.trim(),
      );

      await CacheManager().updateCustomExam(oldCourseName, oldDate, newExam);
      setState(() {
        final index = _customExams.indexWhere(
          (e) => e.courseName == oldCourseName && e.date == oldDate,
        );
        if (index != -1) {
          _customExams[index] = newExam;
        }
      });
    }
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
            ElevatedButton(onPressed: _fetchExams, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_allExams.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('暂无考试安排'),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _fetchExams, child: const Text('刷新')),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _showAddExamDialog,
              child: const Text('手动添加'),
            ),
          ],
        ),
      );
    }

    // Sort all exams
    final sortedExams = List<Exam>.from(_allExams);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    sortedExams.sort((a, b) {
      int getStatus(Exam e) {
        if (e.time == '未安排' ||
            e.time == '无考试信息' ||
            e.time == '获取失败' ||
            e.date.isEmpty) {
          return 2;
        }
        final d = DateTime.tryParse(e.date);
        if (d == null) return 2;
        final eDate = DateTime(d.year, d.month, d.day);
        if (eDate.isBefore(today)) return 1;
        return 0;
      }

      final statusA = getStatus(a);
      final statusB = getStatus(b);
      if (statusA != statusB) return statusA.compareTo(statusB);
      return a.date.compareTo(b.date);
    });

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: sortedExams.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final exam = sortedExams[index];
        final isCustom = _customExams.any(
          (e) => e.courseName == exam.courseName && e.date == exam.date,
        );
        return _ExamCard(
          exam: exam,
          isCustom: isCustom,
          onEdit: isCustom ? () => _showEditExamDialog(exam) : null,
          onDelete: isCustom
              ? () async {
                  await CacheManager().removeCustomExam(
                    exam.courseName,
                    exam.date,
                  );
                  setState(() {
                    _customExams.removeWhere(
                      (e) =>
                          e.courseName == exam.courseName &&
                          e.date == exam.date,
                    );
                  });
                }
              : null,
        );
      },
    );
  }
}

class _ExamCard extends StatelessWidget {
  const _ExamCard({
    required this.exam,
    this.isCustom = false,
    this.onEdit,
    this.onDelete,
  });

  final Exam exam;
  final bool isCustom;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final isScheduled =
        exam.time != '未安排' && exam.time != '无考试信息' && exam.time != '获取失败';

    // Determine if finished
    bool isFinished = false;
    if (isScheduled && exam.date.isNotEmpty) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final d = DateTime.tryParse(exam.date);
      if (d != null) {
        final examDate = DateTime(d.year, d.month, d.day);
        if (examDate.isBefore(today)) {
          isFinished = true;
        }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: isFinished ? Colors.grey.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCustom
              ? const Color(0xFFFF2400).withOpacity(0.3)
              : Colors.grey.shade200,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isCustom)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF2400).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '手动',
                    style: TextStyle(
                      fontSize: 10,
                      color: Color(0xFFFF2400),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Expanded(
                child: Text(
                  exam.courseName,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isFinished ? Colors.grey : const Color(0xFF1F2A44),
                  ),
                ),
              ),
              if (isCustom && onEdit != null)
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  color: Colors.blue.shade400,
                  onPressed: onEdit,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              if (isCustom && onEdit != null && onDelete != null)
                const SizedBox(width: 8),
              if (isCustom && onDelete != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: Colors.red.shade300,
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('删除确认'),
                        content: Text('确定要删除"${exam.courseName}"的考试吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消'),
                          ),
                          ElevatedButton(
                            onPressed: () {
                              Navigator.pop(context);
                              onDelete?.call();
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                            ),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    );
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              if (!isScheduled || isFinished)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    !isScheduled
                        ? (exam.time.isEmpty ? '未安排' : exam.time)
                        : '已结束',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ),
            ],
          ),
          if (isScheduled) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            // Date and Time Row
            Row(
              children: [
                _buildInfoItem(Icons.calendar_today, exam.date, size: 15),
                const SizedBox(width: 24),
                _buildInfoItem(Icons.access_time, exam.time, size: 15),
              ],
            ),
            const SizedBox(height: 8),
            // Location and Seat Row
            Row(
              children: [
                Expanded(
                  child: _buildInfoItem(
                    Icons.location_on,
                    exam.location,
                    size: 15,
                  ),
                ),
                if (exam.seat.isNotEmpty) ...[
                  const SizedBox(width: 16),
                  _buildInfoItem(Icons.chair, '${exam.seat}座', size: 15),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoItem(IconData icon, String text, {double size = 14}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: size, color: Colors.blueGrey.shade400),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF475569),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// _showCaptchaDialog removed
