import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../model/schedule.dart';
import '../model/lecture.dart';
import '../model/score.dart';
import '../model/exam.dart';

class CacheManager {
  static final CacheManager _instance = CacheManager._internal();
  factory CacheManager() => _instance;
  CacheManager._internal();

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // Schedule
  Future<void> saveSchedule(Schedule schedule) async {
    if (_prefs == null) await init();
    try {
      final jsonStr = jsonEncode(schedule.toJson());
      await _prefs!.setString('cache_schedule', jsonStr);
    } catch (e) {
      // ignore
    }
  }

  Future<Schedule?> getSchedule() async {
    if (_prefs == null) await init();
    final jsonStr = _prefs!.getString('cache_schedule');
    if (jsonStr == null) return null;
    try {
      final jsonMap = jsonDecode(jsonStr);
      return Schedule.fromJson(jsonMap);
    } catch (e) {
      return null;
    }
  }

  // Lectures
  Future<void> saveLectures(List<Lecture> lectures) async {
    if (_prefs == null) await init();
    try {
      final jsonList = lectures.map((e) => e.toJson()).toList();
      final jsonStr = jsonEncode(jsonList);
      await _prefs!.setString('cache_lectures', jsonStr);
    } catch (e) {
      // ignore
    }
  }

  Future<List<Lecture>> getLectures() async {
    if (_prefs == null) await init();
    final jsonStr = _prefs!.getString('cache_lectures');
    if (jsonStr == null) return [];
    try {
      final jsonList = jsonDecode(jsonStr) as List;
      return jsonList.map((e) => Lecture.fromJson(e)).toList();
    } catch (e) {
      return [];
    }
  }

  // Scores
  Future<void> saveScores(List<Score> scores) async {
    if (_prefs == null) await init();
    try {
      final jsonList = scores.map((e) => e.toJson()).toList();
      final jsonStr = jsonEncode(jsonList);
      await _prefs!.setString('cache_scores', jsonStr);
    } catch (e) {
      // ignore
    }
  }

  Future<List<Score>> getScores() async {
    if (_prefs == null) await init();
    final jsonStr = _prefs!.getString('cache_scores');
    if (jsonStr == null) return [];
    try {
      final jsonList = jsonDecode(jsonStr) as List;
      return jsonList.map((e) => Score.fromJson(e)).toList();
    } catch (e) {
      return [];
    }
  }

  // Exams
  Future<void> saveExams(List<Exam> exams) async {
    if (_prefs == null) await init();
    try {
      final jsonList = exams.map((e) => e.toJson()).toList();
      final jsonStr = jsonEncode(jsonList);
      await _prefs!.setString('cache_exams', jsonStr);
    } catch (e) {
      // ignore
    }
  }

  Future<List<Exam>> getExams() async {
    if (_prefs == null) await init();
    final jsonStr = _prefs!.getString('cache_exams');
    if (jsonStr == null) return [];
    try {
      final jsonList = jsonDecode(jsonStr) as List;
      return jsonList.map((e) => Exam.fromJson(e)).toList();
    } catch (e) {
      return [];
    }
  }

  // SEP portal cards (profile / credit / summary)
  Future<void> savePortalData(Map<String, dynamic> data) async {
    if (_prefs == null) await init();
    try {
      await _prefs!.setString('cache_portal', jsonEncode(data));
    } catch (_) {}
  }

  Map<String, dynamic>? getPortalData() {
    if (_prefs == null) return null;
    final jsonStr = _prefs!.getString('cache_portal');
    if (jsonStr == null) return null;
    try {
      return jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // Timestamp
  Future<void> saveLastUpdateTime() async {
    if (_prefs == null) await init();
    await _prefs!.setInt(
      'last_update_timestamp',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<int> getLastUpdateTime() async {
    if (_prefs == null) await init();
    return _prefs!.getInt('last_update_timestamp') ?? 0;
  }

  // Custom Courses (Saved Lectures/Exams)
  Future<void> addCustomCourse(Course course) async {
    if (_prefs == null) await init();
    final current = await getCustomCourses();
    // Avoid duplicates by ID or content?
    // Lectures don't have UUIDs really, but ID exists.
    // Let's just append.
    current.add(course);

    try {
      final jsonList = current.map((e) => e.toJson()).toList();
      await _prefs!.setString('cache_custom_courses', jsonEncode(jsonList));
    } catch (_) {}
  }

  Future<List<Course>> getCustomCourses() async {
    if (_prefs == null) await init();
    final jsonStr = _prefs!.getString('cache_custom_courses');
    if (jsonStr == null) return [];
    try {
      final jsonList = jsonDecode(jsonStr) as List;
      return jsonList.map((e) => Course.fromJson(e)).toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> removeCustomCourse(String id) async {
    if (_prefs == null) await init();
    final current = await getCustomCourses();
    current.removeWhere((c) => c.id == id);
    try {
      final jsonList = current.map((e) => e.toJson()).toList();
      await _prefs!.setString('cache_custom_courses', jsonEncode(jsonList));
    } catch (_) {}
  }

  // Custom Exams (Manual Entry)
  Future<void> addCustomExam(Exam exam) async {
    if (_prefs == null) await init();
    final current = await getCustomExams();
    current.add(exam);
    try {
      final jsonList = current.map((e) => e.toJson()).toList();
      await _prefs!.setString('cache_custom_exams', jsonEncode(jsonList));
    } catch (_) {}
  }

  Future<List<Exam>> getCustomExams() async {
    if (_prefs == null) await init();
    final jsonStr = _prefs!.getString('cache_custom_exams');
    if (jsonStr == null) return [];
    try {
      final jsonList = jsonDecode(jsonStr) as List;
      return jsonList.map((e) => Exam.fromJson(e)).toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> removeCustomExam(String courseName, String date) async {
    if (_prefs == null) await init();
    final current = await getCustomExams();
    current.removeWhere((e) => e.courseName == courseName && e.date == date);
    try {
      final jsonList = current.map((e) => e.toJson()).toList();
      await _prefs!.setString('cache_custom_exams', jsonEncode(jsonList));
    } catch (_) {}
  }

  Future<void> updateCustomExam(
    String oldCourseName,
    String oldDate,
    Exam newExam,
  ) async {
    if (_prefs == null) await init();
    final current = await getCustomExams();
    final index = current.indexWhere(
      (e) => e.courseName == oldCourseName && e.date == oldDate,
    );
    if (index != -1) {
      current[index] = newExam;
      try {
        final jsonList = current.map((e) => e.toJson()).toList();
        await _prefs!.setString('cache_custom_exams', jsonEncode(jsonList));
      } catch (_) {}
    }
  }
}
