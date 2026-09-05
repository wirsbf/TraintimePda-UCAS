import 'package:flutter/foundation.dart';

/// SEP portal card data (see docs/protocol-notes-2026-09.md §5).
class SepProfile {
  const SepProfile({
    required this.name,
    required this.balance,
    this.cardNo = '',
    this.cardExpiry = '',
    this.profession = '',
    this.teacher = '',
    this.institute = '',
    this.schoolLength = '',
    this.schoolDate = '',
    this.objectType = '',
  });

  factory SepProfile.fromJson(Map<String, dynamic> json) {
    final d = (json['data'] as Map<String, dynamic>?) ?? const {};
    final card = (d['oneCard'] as Map<String, dynamic>?) ?? const {};
    return SepProfile(
      name: (d['name'] as String?) ?? '',
      balance: int.tryParse('${card['balance'] ?? 0}') ?? 0,
      cardNo: '${card['cardno'] ?? ''}',
      cardExpiry: '${card['effectdate'] ?? ''}'.split(' ').first,
      profession: '${d['professionName'] ?? ''}',
      teacher: '${d['teacher'] ?? ''}',
      institute: '${d['pydwName'] ?? ''}',
      schoolLength: '${d['schoolLength'] ?? ''}',
      schoolDate: '${d['schoolDate'] ?? ''}',
      objectType: '${d['objectType'] ?? ''}',
    );
  }

  final String name;
  final int balance; // 一卡通余额（元）
  final String cardNo;
  final String cardExpiry;
  final String profession;
  final String teacher;
  final String institute;
  final String schoolLength;
  final String schoolDate;
  final String objectType;
}

/// 学分进度 (/sepCardData/dataScore)
class CreditProgress {
  const CreditProgress({
    required this.category,
    required this.totalRequired,
    required this.totalObtained,
    required this.enrolled,
    this.items = const [],
  });

  factory CreditProgress.fromJson(Map<String, dynamic> json) {
    final d = (json['data'] as Map<String, dynamic>?) ?? const {};
    String strip(String s) => s.replaceAll(RegExp(r'[^0-9.]'), '');

    T? map<T>(String key, T Function(Map<String, dynamic>) f) {
      final v = d[key];
      return v is Map<String, dynamic> ? f(v) : null;
    }

    final total = map('zxfyq', (m) => _Req(
          requirement: '${m['yq'] ?? ''}',
          obtained: '${m['yxxf'] ?? ''}',
          enrolled: '${m['yqxf'] ?? ''}',
          ok: m['status'] == true,
        ));
    final major = map('zyxwk', (m) => _Req(
          requirement: '${m['yq'] ?? ''}',
          obtained: '${m['yxxf'] ?? ''}',
          enrolled: '${m['yqxf'] ?? ''}',
          ok: m['status'] == true,
        ));
    final public = map('ggxxk', (m) => _Req(
          requirement: '${m['yq'] ?? ''}',
          obtained: '${m['yxxf'] ?? ''}',
          enrolled: '${m['yqxf'] ?? ''}',
          ok: m['status'] == true,
        ));

    final requiredCourses = (d['ggbxkyq'] as List<dynamic>? ?? const [])
        .map((e) => '$e')
        .toList();

    return CreditProgress(
      category: '${d['xslb'] ?? ''}',
      totalRequired: strip(total?.requirement ?? ''),
      totalObtained: strip(total?.obtained ?? ''),
      enrolled: strip(total?.enrolled ?? total?.obtained ?? ''),
      items: [
        if (major != null)
          _Req(requirement: major.requirement, obtained: major.obtained, enrolled: major.enrolled, ok: major.ok),
        if (public != null)
          _Req(requirement: public.requirement, obtained: public.obtained, enrolled: public.enrolled, ok: public.ok),
        ...requiredCourses.map((c) => _Req(requirement: c, obtained: '✓', enrolled: '', ok: true)),
      ],
    );
  }

  final String category; // 学术型硕士
  final String totalRequired; // 总学分要求
  final String totalObtained; // 已修
  final String enrolled; // 在读
  final List<_Req> items; // 分项

  double get progress {
    final req = double.tryParse(totalRequired) ?? 0;
    final got = double.tryParse(totalObtained) ?? 0;
    if (req <= 0) return 1;
    return (got / req).clamp(0.0, 1.0);
  }
}

class _Req {
  const _Req({
    required this.requirement,
    required this.obtained,
    required this.enrolled,
    required this.ok,
  });
  final String requirement;
  final String obtained;
  final String enrolled;
  final bool ok;
}

/// 我的课程概览 (/sepCardData/data/card_mycourse)
class CourseSummary {
  const CourseSummary({
    required this.selectedCount,
    required this.gpa,
    required this.obtainedCredit,
  });

  factory CourseSummary.fromJson(Map<String, dynamic> json) {
    final d = (json['data'] as Map<String, dynamic>?) ?? const {};
    return CourseSummary(
      selectedCount: int.tryParse('${d['selectedCourseSize'] ?? 0}') ?? 0,
      gpa: '${d['gpa'] ?? ''}',
      obtainedCredit: '${d['obtainedCredit'] ?? ''}',
    );
  }

  final int selectedCount;
  final String gpa;
  final String obtainedCredit;
}

/// 提醒项 (/sepCardData/reminderPage) — 作业督促通知等
class SepReminder {
  const SepReminder({
    required this.id,
    required this.title,
    required this.time,
    this.link = '',
    this.read = false,
  });

  factory SepReminder.fromJson(Map<String, dynamic> json) {
    return SepReminder(
      id: json['id'] ?? json['reminderId'] ?? '',
      title: '${json['title'] ?? json['content'] ?? ''}',
      time: '${json['createTime'] ?? json['publishTime'] ?? json['time'] ?? ''}',
      link: '${json['url'] ?? json['link'] ?? ''}',
      read: json['status'] == 1 || json['read'] == true,
    );
  }

  final dynamic id;
  final String title;
  final String time;
  final String link;
  final bool read;
}

/// 评教课程（xkcts /evaluate/course/{termId}）
@immutable
class EvalCourse {
  const EvalCourse({
    required this.code,
    required this.name,
    required this.teacher,
    required this.termId,
    this.evaluated = true,
    this.actionUrl,
  });

  final String code;
  final String name;
  final String teacher;
  final String termId;
  final bool evaluated; // 操作区为空 = 已评估
  final String? actionUrl; // 未评估时的评估链接
}
