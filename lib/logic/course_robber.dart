import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../data/ucas_client.dart';
import '../data/settings_controller.dart';

enum RobberStatus { idle, running, success, stopped, error }

class RobLog {
  final DateTime time;
  final String message;
  final bool isError;
  RobLog(this.message, {this.isError = false}) : time = DateTime.now();
}

class CourseTarget {
  final String fullCode; // e.g. "091M4001H" or sids for selection
  final String name; // e.g. "高级软件工程"
  bool selected = false; // Whether successfully selected
  
  // Rich info for UI display
  final String teacher;
  final String attribute;
  final String level;
  final String teachingMethod;
  final String examMethod;

  CourseTarget({
    required this.fullCode,
    required this.name,
    this.teacher = '',
    this.attribute = '',
    this.level = '',
    this.teachingMethod = '',
    this.examMethod = '',
  });
}

/// Search result from course query
class SearchResult {
  final String sids;       // Selection ID
  final String code;       // Course code
  final String name;       // Course name  
  final String teacher;    // Teacher
  final String time;       // Schedule
  final String location;   // Classroom
  final int enrolled;      // Current enrollment
  final int capacity;      // Max capacity
  
  // New fields
  final String attribute;      // 课程属性
  final String level;          // 培养层次
  final String teachingMethod; // 授课方式
  final String examMethod;     // 考试方式

  SearchResult({
    required this.sids,
    required this.code,
    required this.name,
    required this.teacher,
    required this.time,
    required this.location,
    required this.enrolled,
    required this.capacity,
    this.attribute = '',
    this.level = '',
    this.teachingMethod = '',
    this.examMethod = '',
  });

  bool get isFull => enrolled >= capacity;
  String get enrollmentStatus => '$enrolled/$capacity';
}



class CourseRobber extends ChangeNotifier {
  // Use singleton instance instead of creating new client
  UcasClient get _client => UcasClient.instance;
  final SettingsController _settings;

  /// Maximum OCR attempts before requesting manual input
  static const int _maxOcrRetries = 3;

  RobberStatus _status = RobberStatus.idle;
  RobberStatus get status => _status;

  final List<RobLog> _logs = [];
  List<RobLog> get logs => List.unmodifiable(_logs);

  final List<CourseTarget> _targets = [];
  List<CourseTarget> get targets => List.unmodifiable(_targets);

  // Search results
  final List<SearchResult> _searchResults = [];
  List<SearchResult> get searchResults => List.unmodifiable(_searchResults);
  bool _isSearching = false;
  bool get isSearching => _isSearching;
  String? _searchError;
  String? get searchError => _searchError;

  Timer? _timer;
  bool _isStopping = false;

  /// Callback for manual captcha input when OCR fails after retries.
  /// UI should set this to show a dialog and return the user-entered code.
  /// Return null to abort the current operation.
  Future<String?> Function(Uint8List imageBytes)? onManualCaptchaNeeded;

  int get robInterval => _settings.robInterval;
  
  void setRobInterval(int ms) {
    _settings.updateRobInterval(ms);
    notifyListeners(); 
  }

  CourseRobber(this._settings);

  void addTarget(String code, String name) {
    _targets.add(CourseTarget(fullCode: code, name: name));
    notifyListeners();
  }

  void removeTarget(int index) {
    _targets.removeAt(index);
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  /// Search for courses by name or code
  Future<void> searchCourses(String query, {bool isCode = false}) async {
    if (query.trim().isEmpty) {
      _searchResults.clear();
      _searchError = null;
      notifyListeners();
      return;
    }

    _isSearching = true;
    _searchError = null;
    notifyListeners();

    try {
      final htmlStr = await _client.searchCourse(query, isCode: isCode);
      _searchResults.clear();
      
      // Parse HTML to extract courses
      final doc = html.parse(htmlStr);
      final rows = doc.querySelectorAll('tr');
      
      for (final row in rows) {
        final cells = row.querySelectorAll('td');
        if (cells.length > 13) {
          // Extract info based on confirmed indices
          final checkbox = row.querySelector('input[type="checkbox"]');
          final sids = checkbox?.attributes['value'] ?? '';
          
          if (sids.isEmpty) continue;

          // Col3: Code, Col4: Name
          final code = cells[3].text.trim();
          final name = cells[4].text.trim();
          
          // Col9: Attribute, Col10: Level, Col11: Method, Col12: Exam, Col13: Teacher
          final attribute = cells[9].text.trim();
          final level = cells[10].text.trim();
          final teachingMethod = cells[11].text.trim();
          final examMethod = cells[12].text.trim();
          final teacher = cells[13].text.trim();
          
          // Col7: Capacity, Col8: Enrolled
          int capacity = int.tryParse(cells[7].text.trim()) ?? 0;
          int enrolled = int.tryParse(cells[8].text.trim()) ?? 0;
          
          // Time/Location not in these columns
          final time = '';
          final location = '';

          _searchResults.add(SearchResult(
            sids: sids,
            code: code,
            name: name,
            teacher: teacher,
            time: time,
            location: location,
            enrolled: enrolled,
            capacity: capacity,
            attribute: attribute,
            level: level,
            teachingMethod: teachingMethod,
            examMethod: examMethod,
          ));
        }
      }
      
      if (_searchResults.isEmpty) {
        _searchError = '未找到匹配课程';
      }
    } catch (e) {
      _searchError = '搜索失败: $e';
      _searchResults.clear();
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  /// Add course from search results to targets
  void addFromSearch(SearchResult course) {
    // Check if already added
    if (_targets.any((t) => t.fullCode == course.sids)) {
      return;
    }
    _targets.add(CourseTarget(
      fullCode: course.code, // Use visible code for matching/searching
      name: course.name,
      teacher: course.teacher,
      attribute: course.attribute,
      level: course.level,
      teachingMethod: course.teachingMethod,
      examMethod: course.examMethod,
    ));
    notifyListeners();
  }

  Future<void> start() async {
    if (_status == RobberStatus.running) return;
    if (_targets.isEmpty) {
      _log("没有添加目标课程", isError: true);
      return;
    }

    _status = RobberStatus.running;
    _isStopping = false;
    _log("开始抢课任务...");
    notifyListeners();

    _log("开始抢课任务...");
    notifyListeners();

    // Check login - uses cached session from initialization
    try {
      // Login no longer needs credentials - uses cached session
      await _client.login(_settings.username, _settings.password);
      _log("登录成功");
    } catch (e) {
      _log("登录失败: $e", isError: true);
      _stop(RobberStatus.error);
      return;
    }

    // Start loop
    _loop();
  }

  void stop() {
    _isStopping = true;
    _log("正在停止...");
  }

  void _stop(RobberStatus finalStatus) {
    _isStopping = true; // Ensure loop terminates
    _status = finalStatus;
    _timer?.cancel();
    notifyListeners();
  }

  void _log(String msg, {bool isError = false}) {
    _logs.add(RobLog(msg, isError: isError));
    // Keep log size manageable
    if (_logs.length > 500) {
      _logs.removeRange(0, 100);
    }
    notifyListeners();
  }

  Future<void> _loop() async {
    while (!_isStopping) {
      // Check if all done
      if (_targets.every((t) => t.selected)) {
        _log("所有课程已选上！");
        _stop(RobberStatus.success);
        return;
      }

      for (var target in _targets) {
        if (target.selected) continue;
        if (_isStopping) break;

        await _processTarget(target);

        // Random usage delay between targets
        await Future.delayed(const Duration(milliseconds: 1500));
      }

      if (_isStopping) break;

      // Loop delay
      await Future.delayed(const Duration(seconds: 3));
    }
    _stop(RobberStatus.stopped);
  }

  Future<void> _processTarget(CourseTarget target) async {
    _log("搜索课程: ${target.fullCode.isNotEmpty ? target.fullCode : target.name}");

    try {
      final htmlStr = target.fullCode.isNotEmpty
          ? await _client.searchCourse(target.fullCode, isCode: true)
          : await _client.searchCourse(target.name);

      // Parse rows
      // Regex or HTML parser. Let's use HTML parser for robustness if regex is flaky,
      // but the Python used regex. Let's stick to regex to match the logic exactly if precise.
      // Or simpler: find the row containing the code.

      // Python logic:
      // re.findall(r'<tr>\s*<td><input type="checkbox".*?</tr>', r.text, re.DOTALL)
      // Check code, name.

      // Let's use simplified string search/parsing
      final doc = html.parse(htmlStr);
      final rows = doc.querySelectorAll('tr');

      String? sids;
      bool isFull = false;
      bool isConflict =
          false; // -1 in python means "selected" (or conflict/exist)

      for (var row in rows) {
        final text = row.text;
        // Check if it's the right course
        // Python script: checks id="courseCode_..." span text
        final codeSpan = row.querySelector('span[id^="courseCode_"]');
        if (codeSpan == null) continue;

        if (!codeSpan.text.contains(target.fullCode)) continue;

        // It matches!
        // Check availability
        // Regex red: <td class="m-font-red">(\d+)</td> -> This usually implies FULL waitlist count?
        // Python: if r.text.count(courseCode) == 1 => return -1 (Already selected?)
        // Logic from python `course_available`:
        // if text.count(code) == 1 -> -1 (Done/Conflict)
        // match red -> 0 (Full)
        // else -> match input value (Available)

        if (row.innerHtml.contains('class="m-font-red"')) {
          isFull = true;
        } else {
          final checkbox = row.querySelector(
            'input[type="checkbox"][name="sids"]',
          );
          if (checkbox != null) {
            if (checkbox.attributes.containsKey('disabled')) {
              // Disabled usually means full or time conflict?
              // Actually python script says: 'disabled' not in attrs => available
            } else {
              sids = checkbox.attributes['value'];
            }
          }
        }
        break; // Found our row
      }

      if (htmlStr.contains('已选') ||
          (sids == null && !isFull && htmlStr.contains(target.fullCode))) {
        // Heuristic: if we found the code but no checkbox, maybe it's already selected?
        // Python logic is `r.text.count(courseCode) == 1` -> selected.
        // Let's assume if we can't find a checkbox but code is there, and not full, it might be done.
        // Better: check "已选课程" list separately?
        // For now, adhere to "sids found = try to rob".
      }

      if (sids != null) {
        _log("发现名额! Sids: $sids. 正在尝试选课...");
        await _attemptSelect(sids, target);
      } else if (isFull) {
        _log("${target.name}:此处已满");
      } else {
        _log("${target.name}: 未找到有效选课选项 (可能已选/冲突/未开课)");
        // If we rely on logs, maybe mark selected?
        // Actually, sticking to the aggressive python logic: keep retrying unless we are SURE.
      }
    } catch (e) {
      _log("处理课程 ${target.name} 出错: $e", isError: true);
    }
  }

  // TFLite OCR instance (Removed)
  // final TfliteLocalOcr _ocr = TfliteLocalOcr();

  Future<void> _attemptSelect(String sids, CourseTarget target) async {
    // Retry loop for captcha
    int retries = 0;
    while (retries < 5) {
      retries++;
      try {
        final start = DateTime.now();
        var bytes = await _client.getCourseSelectionCaptcha();
        
        // Check if it's a data URL (base64 encoded)
        final dataUrlPrefix = 'data:image/';
        final bytesStr = String.fromCharCodes(bytes);
        if (bytesStr.startsWith(dataUrlPrefix)) {
          // Extract base64 part after "data:image/png;base64," or similar
          final commaIndex = bytesStr.indexOf(',');
          if (commaIndex != -1) {
            final base64Str = bytesStr.substring(commaIndex + 1);
            bytes = base64Decode(base64Str);
            _log("已解码 Base64 验证码 (${bytes.length} bytes)");
          }
        }

        String? code;

        // OCR 已移除（模型 48MB + onnxruntime 原生库 ~32MB，为缩减包体）。
        // 抢课验证码直接请求手动输入。
        _log("请求手动输入验证码...");
        if (onManualCaptchaNeeded != null) {
          code = await onManualCaptchaNeeded!(bytes);
          if (code != null && code.isNotEmpty) {
            _log("用户手动输入验证码: $code");
          }
        }

        if (code == null || code.isEmpty) {
          _log("验证码获取失败（无自动识别且用户未输入），跳过本次尝试", isError: true);
          continue; // Continue outer retry loop instead of stopping
        }

        // Submit
        final result = await _client.saveCourse(sids, code);
        final elapsed = DateTime.now().difference(start).inMilliseconds;

        // Analyze result - check for FAILURES first, then success
        final lowerResult = result.toLowerCase();
        
        // Check for time conflict (highest priority error)
        if (result.contains('冲突') || result.contains('时间重叠') || 
            result.contains('conflict') || result.contains('已有课程')) {
          _log("!!! 选课失败: 时间冲突 - ${target.name} !!!", isError: true);
          return;
        }
        
        // Check for captcha error (should retry)
        if (result.contains('验证码错误') || result.contains('验证码不正确') ||
            result.contains('captcha') || result.contains('vcode')) {
          _log("验证码错误 ($code)，重试...");
          continue;
        }
        
        // Check for course full
        if (result.contains('已满') || result.contains('满员') ||
            result.contains('人数已满') || result.contains('full')) {
          _log("课程已满: ${target.name}", isError: true);
          return;
        }
        
        // Check for already selected
        if (result.contains('已选') || result.contains('重复') ||
            result.contains('已经选过') || result.contains('already')) {
          _log("已选过该课: ${target.name}");
          target.selected = true;
          return;
        }
        
        // Check for success (only after eliminating failures)
        // Be more strict: require exact success message
        if (result.contains('选课成功') || result.contains('保存成功') ||
            (result.contains('成功') && !result.contains('不成功') && !result.contains('未成功'))) {
          _log("!!! 抢课成功: ${target.name} (耗时${elapsed}ms) !!!");
          target.selected = true;
          return;
        }
        
        // Unknown error - log full response
        _log("抢课返回未知结果: $result", isError: true);
        return;
      } catch (e) {
        _log("选课请求异常: $e", isError: true);
        return;
      }
    }
  }




}
