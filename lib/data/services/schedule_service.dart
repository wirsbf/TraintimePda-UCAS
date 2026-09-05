import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import '../auth/xkgo_authentication_service.dart';
import '../auth/jwxk_authentication_service.dart';
import '../utils/http_helper.dart';
import '../../model/schedule.dart';

/// Internal helper classes for schedule parsing
class _Weekday {
  const _Weekday(this.cn, this.english, this.dayIndex);

  final String cn;
  final String english;
  final int dayIndex;

  static const monday = _Weekday('周一', 'Monday', 0);
  static const tuesday = _Weekday('周二', 'Tuesday', 1);
  static const wednesday = _Weekday('周三', 'Wednesday', 2);
  static const thursday = _Weekday('周四', 'Thursday', 3);
  static const friday = _Weekday('周五', 'Friday', 4);
  static const saturday = _Weekday('周六', 'Saturday', 5);
  static const sunday = _Weekday('周日', 'Sunday', 6);

  static _Weekday? fromChinese(String label) {
    switch (label) {
      case '星期一':
      case '周一':
        return monday;
      case '星期二':
      case '周二':
        return tuesday;
      case '星期三':
      case '周三':
        return wednesday;
      case '星期四':
      case '周四':
        return thursday;
      case '星期五':
      case '周五':
        return friday;
      case '星期六':
      case '周六':
        return saturday;
      case '星期日':
      case '周日':
      case '星期天':
        return sunday;
      default:
        return null;
    }
  }
}

class _CourseEntry {
  const _CourseEntry({
    required this.name,
    required this.weekday,
    required this.startSection,
    required this.endSection,
    required this.courseId,
    required this.detailLink,
  });

  final String name;
  final _Weekday weekday;
  final int startSection;
  final int endSection;
  final String? courseId;
  final String? detailLink;
}

class _CourseGroup {
  _CourseGroup({
    required this.name,
    required this.weekday,
    required this.courseId,
    required this.detailLink,
    required this.sections,
  });

  final String name;
  final _Weekday weekday;
  final String? courseId;
  final String? detailLink;
  final Set<int> sections;
}

class _CourseDetail {
  _CourseDetail({
    required this.timeText,
    required this.location,
    required this.weeksList,
    required this.teacher,
  });

  factory _CourseDetail.empty() {
    return _CourseDetail(
      timeText: '',
      location: '',
      weeksList: [],
      teacher: '待定',
    );
  }

  String timeText;
  String location;
  List<String> weeksList;
  String teacher;

  String get weeks {
    if (weeksList.isEmpty) return '未标注';
    return weeksList.join('、');
  }
}

class _MergedCourse {
  _MergedCourse({
    required this.id,
    required this.name,
    required this.weekday,
    required this.startSection,
    required this.endSection,
    required this.teacher,
    required this.classroom,
    required this.timeText,
    required String weeks,
  }) {
    addWeeks(weeks);
  }

  final String id;
  final String name;
  final _Weekday weekday;
  final int startSection;
  final int endSection;
  final String teacher;
  final String classroom;
  final String timeText;
  final Set<int> _weekSet = {};

  void addWeeks(String weeksStr) {
    if (weeksStr == '未标注') return;

    // Parse weeks string like "2、3、4、5" or "1-16"
    final parts = weeksStr.split(RegExp(r'[、,，\s]+'));
    for (final part in parts) {
      final trimPart = part.trim();
      if (trimPart.contains('-')) {
        final rangeParts = trimPart.split('-');
        if (rangeParts.length == 2) {
          final start = int.tryParse(rangeParts[0]);
          final end = int.tryParse(rangeParts[1]);
          if (start != null && end != null && start <= end) {
            for (var i = start; i <= end; i++) {
              _weekSet.add(i);
            }
            continue;
          }
        }
      }
      
      final week = int.tryParse(trimPart);
      if (week != null) {
        _weekSet.add(week);
      }
    }
  }

  String getMergedWeeks() {
    if (_weekSet.isEmpty) return '未标注';
    final sorted = _weekSet.toList()..sort();
    return sorted.join('、');
  }
}

/// Schedule service for fetching course schedules from XKGO system
class ScheduleService {
  ScheduleService({
    required Dio dio,
    required XkgoAuthenticationService xkgoAuth,
    required JwxkAuthenticationService jwxkAuth,
  })  : _dio = dio,
        _xkgoAuth = xkgoAuth,
        _jwxkAuth = jwxkAuth,
        _httpHelper = HttpHelper(dio);

  final Dio _dio;
  final XkgoAuthenticationService _xkgoAuth;
  final JwxkAuthenticationService _jwxkAuth;
  final HttpHelper _httpHelper;

  static const String _schedulePath = '/course/personSchedule';
  static const String _courseDetailPath = '/course/coursetime';

  /// Fetch personal schedule
  Future<Schedule> fetchSchedule() async {
    // Ensure authentication
    if (!await _xkgoAuth.validateSession()) {
      throw Exception('XKGO session not valid. Please authenticate first.');
    }

    final scheduleHtml = await _fetchScheduleHtml();
    final entries = _parseScheduleTable(scheduleHtml);

    if (entries.isEmpty) {
      // An empty grid is a valid state (e.g. no courses selected yet this
      // term). Only a missing table means the page was not the schedule.
      if (!scheduleHtml.contains('<table')) {
        throw Exception('No course data parsed from schedule');
      }
      return Schedule(courses: const []);
    }

    final details = await _fetchCourseDetails(entries);
    
    // Fetch teachers from XKGO selected course list
    var extraTeachers = <String, String>{};
    try {
      extraTeachers = await _fetchTeacherInfoFromXkgo();
    } catch (e) {
      print('⚠️ XKGO Teacher fetch failed: $e');
    }

    return _buildSchedule(entries, details, extraTeachers);
  }

  /// Fetch schedule HTML
  Future<String> _fetchScheduleHtml() async {
    final scheduleResponse = await _httpHelper.getFollow(
      '${_xkgoAuth.baseUrl}$_schedulePath',
    );
    return scheduleResponse.data ?? '';
  }

  /// Parse schedule table to extract course entries
  List<_CourseEntry> _parseScheduleTable(String html) {
    final document = html_parser.parse(html);
    final table = document.querySelector('table');

    if (table == null) return [];

    // Parse weekdays from header row
    final weekdays = _parseWeekdays(table);
    if (weekdays.isEmpty) return [];

    // Parse course data
    final idRegex = RegExp(r'/course/coursetime/(\d+)');
    final grouped = <String, _CourseGroup>{};

    for (final row in table.querySelectorAll('tr')) {
      final th = row.querySelector('th');
      if (th == null) continue;

      final sectionText = th.text.trim();
      final section = int.tryParse(sectionText);
      if (section == null) continue;

      final cells = row.querySelectorAll('td');
      for (var i = 0; i < cells.length && i < weekdays.length; i++) {
        final cell = cells[i];
        final weekday = weekdays[i];
        final links = cell.querySelectorAll('a');

        if (links.isEmpty) {
          final text = cell.text.trim();
          if (text.isNotEmpty) {
            _pushCourseGroup(grouped, weekday, text, null, null, section);
          }
          continue;
        }

        for (final link in links) {
          final name = link.text.trim();
          if (name.isEmpty) continue;
          
          if (grouped.length < 3) {
             print('Debug Cell HTML: ${cell.innerHtml}');
          }

          final href = link.attributes['href'] ?? '';
          final match = idRegex.firstMatch(href);
          final courseId = match?.group(1);
          _pushCourseGroup(grouped, weekday, name, courseId, href, section);
        }
      }
    }

    // Convert grouped courses to entries with consecutive section ranges
    return _groupedToEntries(grouped);
  }

  /// Parse weekday headers from table
  List<_Weekday> _parseWeekdays(dynamic table) {
    for (final row in table.querySelectorAll('tr')) {
      final ths = row.querySelectorAll('th');
      final tds = row.querySelectorAll('td');

      // Header row has multiple th and no td
      if (ths.length > 1 && tds.isEmpty) {
        return ths
            .skip(1) // Skip first column (section number)
            .map((cell) => _Weekday.fromChinese(cell.text.trim()))
            .whereType<_Weekday>()
            .toList();
      }
    }

    return [];
  }

  /// Add course to grouped map
  void _pushCourseGroup(
    Map<String, _CourseGroup> grouped,
    _Weekday weekday,
    String name,
    String? courseId,
    String? detailLink,
    int section,
  ) {
    final key = '${weekday.dayIndex}::$name::${courseId ?? ""}';
    final group = grouped.putIfAbsent(
      key,
      () => _CourseGroup(
        name: name,
        weekday: weekday,
        courseId: courseId,
        detailLink: detailLink,
        sections: {},
      ),
    );
    group.sections.add(section);
  }

  /// Convert grouped courses to entries with consecutive section ranges
  List<_CourseEntry> _groupedToEntries(Map<String, _CourseGroup> grouped) {
    final entries = <_CourseEntry>[];

    for (final group in grouped.values) {
      final sortedSections = group.sections.toList()..sort();
      if (sortedSections.isEmpty) continue;

      var start = sortedSections.first;
      var prev = start;

      for (final section in sortedSections.skip(1)) {
        if (section == prev + 1) {
          prev = section;
          continue;
        }

        // Gap detected - create entry for previous range
        entries.add(_CourseEntry(
          name: group.name,
          weekday: group.weekday,
          startSection: start,
          endSection: prev,
          courseId: group.courseId,
          detailLink: group.detailLink,
        ));

        start = section;
        prev = section;
      }

      // Add final entry
      entries.add(_CourseEntry(
        name: group.name,
        weekday: group.weekday,
        startSection: start,
        endSection: prev,
        courseId: group.courseId,
        detailLink: group.detailLink,
      ));
    }

    return entries;
  }

  /// Fetch course details for all course IDs
  Future<Map<String, _CourseDetail>> _fetchCourseDetails(
    List<_CourseEntry> entries,
  ) async {
    final details = <String, _CourseDetail>{};

    // 还原用户提供的逻辑：直接从JWXK获取详情，不带额外Header，依赖共享Cookie
    final ids = entries
        .map((entry) => entry.courseId)
        .whereType<String>()
        .toSet();

    for (final id in ids) {
      // 用户提供的原逻辑：直接访问 $_jwxkBase/course/coursetime/$id
      final url = '${_jwxkAuth.baseUrl}$_courseDetailPath/$id';
      try {
        final response = await _dio.get<String>(
          url,
          options: Options(
            responseType: ResponseType.plain,
            validateStatus: (status) => status != null && status < 500,
          ),
        );

        // 如果获取到了内容，尝试解析
        if (response.statusCode == 200 && response.data != null) {
           final detail = _parseCourseDetail(response.data!);
           details[id] = detail;
        }
      } catch (e) {
        // 静默失败或仅简单打印，恢复简洁性
        print('Error fetching details for $id: $e');
      }
    }

    return details;
  }

  /// Parse course detail page
  _CourseDetail _parseCourseDetail(String html) {
    final document = html_parser.parse(html);
    final rows = document.querySelectorAll('tr');
    final detail = _CourseDetail.empty();

    for (final row in rows) {
      final cells = row.querySelectorAll('th, td');
      if (cells.length < 2) continue;

      final label = cells[0].text.trim();
      final value = cells[1].text.trim();

      switch (label) {
        case '上课时间':
          detail.timeText = value;
          break;
        case '上课地点':
          detail.location = value;
          break;
        case '上课周次':
          detail.weeksList.add(value);
          break;
        case '主讲教师':
        case '教师':
        case '授课教师':
        case '主讲人':
          detail.teacher = value;
          break;
      }
    }
    return detail;
  }

  /// Fetch teacher info from XKGO selected courses page
  Future<Map<String, String>> _fetchTeacherInfoFromXkgo() async {
    final teachers = <String, String>{};
    // Use the dynamic base URL from authentication service (handles seasonal logic)
    final url = '${_xkgoAuth.baseUrl}/courseManage/main';
    
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final document = html_parser.parse(response.data);
        // Look for the course table
        final rows = document.querySelectorAll('table tbody tr');
        
        for (final row in rows) {
          final cells = row.querySelectorAll('td');
          // Table structure usually: [Check], CourseName, Code, ..., Teacher, ...
          // We need to be robust. Let's look for known headers or just iterate.
          // Based on typical structure: 
          // Index 0: Checkbox
          // Index 1: Course Name (link)
          // Index 2: Course Code
          // Index 6: Teacher (usually)
          
          if (cells.length >= 7) {
            final name = cells[1].text.trim();
            final teacher = cells[6].text.trim(); // Adjust index if needed based on inspection
            
            if (name.isNotEmpty && teacher.isNotEmpty) {
               teachers[name] = teacher;
            }
          }
        }
      }
    } catch (e) {
      print('⚠️ Failed to fetch XKGO teacher info: $e');
    }
    
    return teachers;
  }

  /// Build final Schedule from entries and details
  Schedule _buildSchedule(
    List<_CourseEntry> entries,
    Map<String, _CourseDetail> details,
    Map<String, String> extraTeachers,
  ) {
    // Group entries and merge weeks
    final grouped = <String, _MergedCourse>{};
    var counter = 0;

    for (final entry in entries) {
      counter++;
      final detail = entry.courseId != null ? details[entry.courseId!] : null;

      final baseKey = '${entry.name}::${entry.weekday.dayIndex}::'
          '${entry.startSection}::${entry.endSection}';

      final weeks = detail?.weeks ?? '未标注';

      if (grouped.containsKey(baseKey)) {
        grouped[baseKey]!.addWeeks(weeks);
      } else {
        grouped[baseKey] = _MergedCourse(
          id: entry.courseId ?? 'remote-$counter',
          name: entry.name,
          weekday: entry.weekday,
          startSection: entry.startSection,
          endSection: entry.endSection,
          teacher: (detail?.teacher != null && detail!.teacher != '待定' && detail.teacher.isNotEmpty)
              ? detail.teacher
              : (extraTeachers[entry.name] ?? '待定'),
          classroom: detail?.location ?? '待定',
          timeText: detail?.timeText ?? '',
          weeks: weeks,
        );
      }
    }

    // Build Course objects
    final courses = <Course>[];
    for (final merged in grouped.values) {
      final courseId = '${merged.id}-${merged.weekday.dayIndex}-'
          '${merged.startSection}-${merged.endSection}';

      courses.add(Course(
        id: courseId,
        name: merged.name,
        teacher: merged.teacher,
        classroom: merged.classroom,
        weekday: merged.weekday.english,
        timeSlot: TimeSlot(
          startTime: '第${merged.startSection}节',
          endTime: '第${merged.endSection}节',
        ),
        weeks: merged.getMergedWeeks(),
        notes: merged.timeText,
      ));
    }

    return Schedule(courses: courses);
  }
}
