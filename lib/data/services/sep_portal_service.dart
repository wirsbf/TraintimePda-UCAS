import 'dart:convert';

import 'package:dio/dio.dart';

import '../../model/sep_portal.dart';
import '../auth/sep_authentication_service.dart';

/// SEP 门户卡片数据服务（docs/protocol-notes-2026-09.md §5）
///
/// 纯 GET + SEP 登录态（JSESSIONID），无需子系统会话：
/// - /sepCardData/data/sep_info       一卡通余额 + 学籍档案
/// - /sepCardData/dataScore           培养方案学分进度
/// - /sepCardData/data/card_mycourse  GPA / 选课数 / 已修学分
/// - /sepCardData/reminderPage        提醒流（作业督促通知等）
class SepPortalService {
  SepPortalService({required Dio dio, required SepAuthenticationService sepAuth})
      : _dio = dio,
        _sepAuth = sepAuth;

  final Dio _dio;
  final SepAuthenticationService _sepAuth;

  static const String _sepBase = 'https://sep.ucas.ac.cn';

  Future<Map<String, dynamic>> _getJson(String path) async {
    final response = await _dio.get<String>(
      '$_sepBase$path',
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': '$_sepBase/sepCard/card',
          'Accept': 'application/json, text/javascript, */*; q=0.01',
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    final body = response.data ?? '';
    if (body.contains('jsePubKey') || response.statusCode == 302 || response.statusCode == 303) {
      throw const SepPortalAuthException('SEP 会话已失效，请刷新登录');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// 一卡通 + 学籍档案
  Future<SepProfile> fetchProfile() async {
    final json = await _getJson('/sepCardData/data/sep_info');
    return SepProfile.fromJson(json);
  }

  /// 培养方案学分进度
  Future<CreditProgress> fetchCreditProgress() async {
    final json = await _getJson('/sepCardData/dataScore');
    return CreditProgress.fromJson(json);
  }

  /// GPA / 选课数 / 已修学分
  Future<CourseSummary> fetchCourseSummary() async {
    final json = await _getJson('/sepCardData/data/card_mycourse');
    return CourseSummary.fromJson(json);
  }

  /// 提醒流（作业督促通知等），返回最新 [limit] 条
  Future<List<SepReminder>> fetchReminders({int limit = 20}) async {
    final json = await _getJson('/sepCardData/reminderPage?pageNum=1&pageSize=$limit');
    final data = (json['data'] as Map<String, dynamic>?) ?? const {};
    final list = (data['list'] as List<dynamic>? ?? const []);
    return list
        .map((e) => SepReminder.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  /// 通知公告（学生处等部门发布）
  Future<List<SepBulletin>> fetchBulletins({int limit = 20}) async {
    final json = await _getJson('/sepCardData/data/sep_bulletin');
    final list = (json['data'] as List<dynamic>? ?? const []);
    return list
        .map((e) => SepBulletin.fromJson((e as Map).cast<String, dynamic>()))
        .take(limit)
        .toList();
  }

  /// 当前 SEP JSESSIONID 值（供 WebView 注入）
  Future<String> currentSepCookieValue() async {
    final cookie = await _sepAuth.currentSepCookie();
    return cookie.replaceFirst('JSESSIONID=', '');
  }

  /// 公告详情（/noticeDetailJson）：标题/发布人/日期/原文链接
  Future<Map<String, dynamic>> fetchBulletinDetail(dynamic id) async {
    final json = await _getJson('/noticeDetailJson?id=$id');
    return (json['data'] as Map<String, dynamic>?) ?? const {};
  }

  // ==================== 评教（xkcts，需子系统会话） ====================

  String? _xkctsBase;
  String? _xkctsCookie;

  /// 通过门户「学生角色」入口建立 xkcts 会话，
  /// 返回评教学期列表 {termId: 学期名}（来自 /main 菜单）。
  Future<Map<String, String>> establishEvaluationSession() async {
    // 1. 门户入口页 → 提取 Identity 登录链接
    final portalResp = await _dio.get<String>(
      '$_sepBase/portal/site/226/821',
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    final html = portalResp.data ?? '';
    final match =
        RegExp('(https://[^"\\s]+/login\\?Identity=[^"\\s]+)').firstMatch(html);
    final redirectLoc = portalResp.headers.value('location');
    if (match == null && redirectLoc != null && redirectLoc.contains('loginFrom')) {
      throw const SepPortalAuthException('SEP 会话已失效，请刷新登录');
    }
    if (match == null) {
      throw const SepPortalException('未找到评教系统入口（门户页无 Identity 链接）');
    }
    final loginUrl = match.group(1)!;

    // 2. 跟随登录链，收集 xkcts 会话 Cookie
    final uri = Uri.parse(loginUrl);
    final base = '${uri.scheme}://${uri.host}'
        '${uri.hasPort ? ':${uri.port}' : ''}';
    final cookieHeader = await _sepAuth.currentSepCookie();
    var current = loginUrl;
    for (var hop = 0; hop < 6; hop++) {
      final resp = await _dio.get<String>(
        current,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          headers: {'Cookie': cookieHeader},
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final setCookie = resp.headers.map['set-cookie'];
      if (setCookie != null) {
        for (final sc in setCookie) {
          final kv = sc.split(';').first;
          if (kv.contains('=')) {
            _xkctsCookie = _xkctsCookie == null ? kv : '${_xkctsCookie!}; $kv';
          }
        }
      }
      final loc = resp.headers.value('location');
      if (loc == null) break;
      current = loc.startsWith('http') ? loc : '$base$loc';
    }
    _xkctsBase = base;

    // 3. /main 菜单 → 学期列表
    final mainResp = await _xkctsGet('/main');
    final terms = <String, String>{};
    for (final m in RegExp(r'href="\/evaluate\/(?:course|teacher)\/(\d+)"[^>]*>([^<]{2,25})<')
        .allMatches(mainResp)) {
      terms[m.group(1)!] = m.group(2)!.trim();
    }
    return terms;
  }

  Future<String> _xkctsGet(String path) async {
    if (_xkctsBase == null) {
      throw const SepPortalException('评教会话未建立');
    }
    final resp = await _dio.get<String>(
      '$_xkctsBase$path',
      options: Options(
        responseType: ResponseType.plain,
        // Follow redirects: /main 303-redirects to the notice page, and the
        // site-wide menu (with the evaluate links) renders on every page.
        followRedirects: true,
        maxRedirects: 6,
        headers: {'Cookie': _xkctsCookie ?? ''},
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    return resp.data ?? '';
  }

  /// 拉取某学期的评教课程列表。
  /// [type] 'course' = 课程评估，'teacher' = 教师评估。
  Future<List<EvalCourse>> fetchEvaluationCourses({
    required String termId,
    String type = 'course',
  }) async {
    final html = await _xkctsGet('/evaluate/$type/$termId');
    final courses = <EvalCourse>[];
    for (final row in RegExp(r'<tr[^>]*>([\s\S]*?)<\/tr>').allMatches(html)) {
      final cells = RegExp(r'<td[^>]*>([\s\S]*?)<\/td>')
          .allMatches(row.group(1)!)
          .map((c) => c.group(1)!)
          .toList();
      if (cells.length < 8) continue;
      if (cells[0].contains('课程编码')) continue;

      String text(String raw) => raw.replaceAll(RegExp(r'<[^>]+>'), '').trim();

      // 操作区（第8列）含评估链接 = 未评估
      final actionCell = cells[7];
      final actionMatch =
          RegExp(r'href="([^"]+)"').firstMatch(actionCell) ??
          RegExp(r"openLayer\('([^']+)'").firstMatch(actionCell);
      final nameLink = RegExp(r'href="[^"]*"[^>]*>([^<]+)<').firstMatch(cells[1]);

      courses.add(EvalCourse(
        code: text(cells[0]),
        name: nameLink?.group(1)?.trim() ?? text(cells[1]),
        teacher: text(cells[6]),
        termId: termId,
        evaluated: actionMatch == null,
        actionUrl: actionMatch?.group(1),
      ));
    }
    return courses;
  }

  /// 评估操作 URL → 完整地址（供 WebView 打开）
  String resolveActionUrl(String path) {
    if (path.startsWith('http')) return path;
    return '$_xkctsBase$path';
  }
}

class SepPortalException implements Exception {
  const SepPortalException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SepPortalAuthException extends SepPortalException {
  const SepPortalAuthException(super.message);
}
