import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import 'authentication_service.dart';
import 'session_manager.dart';
import 'sep_authentication_service.dart';

/// XKGO/XKGODJ course selection system authentication service
/// 
/// Establishes the course-system session by following the SEP portal redirect
/// (businessMenu "选课" link). The real domain is discovered dynamically from
/// the final redirect target, so semester domain switches no longer break the
/// app. The legacy month-based guess is kept only as a fallback:
/// - January-July: xkgo.ucas.ac.cn:3000
/// - August-December: xkgodj.ucas.ac.cn
/// (2026-09 实测: 9月门户仍指向 xkgo:3000，按月猜测会错选 xkgodj)
class XkgoAuthenticationService implements AuthenticationService {
  XkgoAuthenticationService({
    required Dio dio,
    required SepAuthenticationService sepAuth,
  })  : _dio = dio,
        _sepAuth = sepAuth;

  final Dio _dio;
  final SepAuthenticationService _sepAuth;

  @override
  SessionType get type => SessionType.xkgo;

  @override
  String get baseUrl => _getCurrentXkgoBase();

  static const String _sepBaseUrl = 'https://sep.ucas.ac.cn';
  static const String _menuPath = '/businessMenu';
  static const String _xkgoSpringBase = 'https://xkgo.ucas.ac.cn:3000';
  static const String _xkgoAutumnBase = 'https://xkgodj.ucas.ac.cn';
  static const String _schedulePath = '/course/personSchedule';

  String? _dynamicBaseUrl;

  @override
  Future<AuthResult> authenticate(Credentials credentials) async {
    // Ensure SEP login first
    final sepResult = await _sepAuth.authenticate(credentials);
    if (!sepResult.success) {
      return sepResult;
    }

    // Discover and establish course system session
    try {
      await _establishCourseSystemSession();
      
      if (await validateSession()) {
        return AuthResult.success([]);
      }
      
      return AuthResult.failure('XKGO session not established');
    } catch (e) {
      return AuthResult.failure('XKGO login error: $e');
    }
  }

  @override
  Future<bool> validateSession() async {
    try {
      final response = await _dio.get<String>(
        '$baseUrl$_schedulePath',
        options: Options(
          followRedirects: false,
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      // Check for redirect to login (SEP migrated some redirects to 303)
      if (response.statusCode == 302 || response.statusCode == 303) {
        final location = response.headers.value('location') ?? '';
        if (location.contains('login') || location.contains('sep.ucas')) {
          return false;
        }
      }

      // Check if we got the actual schedule page
      final body = response.data ?? '';
      if (body.contains('login') || body.contains('Identity')) {
        return false;
      }

      // Valid if we got a table or schedule content
      return response.statusCode == 200 && 
             (body.contains('table') || body.contains('课程'));
    } catch (_) {
      return false;
    }
  }

  /// Get current base URL based on season
  String _getCurrentXkgoBase() {
    if (_dynamicBaseUrl != null) {
      return _dynamicBaseUrl!;
    }

    final month = DateTime.now().month;
    // Jan(1) - July(7) -> Spring -> xkgo:3000
    // Aug(8) - Dec(12) -> Autumn -> xkgodj
    return month >= 8 ? _xkgoAutumnBase : _xkgoSpringBase;
  }

  /// Establish course system session by following SEP portal redirect
  Future<void> _establishCourseSystemSession() async {
    // Find course selection link in SEP menu
    final menuHtml = await _getText('$_sepBaseUrl$_menuPath');
    final portalUrl = _findPortalLink(menuHtml, keywords: ['选课']);

    if (portalUrl == null) {
      throw Exception('Cannot find "选课" link in SEP menu');
    }

    // Follow redirect chain
    final portalResponse = await _dio.get<String>(
      portalUrl,
      options: Options(
        followRedirects: false,
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    String? redirectUrl;
    if (portalResponse.statusCode != null &&
        portalResponse.statusCode! >= 300 &&
        portalResponse.statusCode! < 400) {
      redirectUrl = portalResponse.headers.value('location');
    } else {
      redirectUrl = _extractRedirectUrl(portalResponse.data ?? '');
    }

    if (redirectUrl == null || redirectUrl.isEmpty) {
      throw Exception('Failed to get redirect URL from SEP portal');
    }

    if (redirectUrl.startsWith('/')) {
      redirectUrl = '$_sepBaseUrl$redirectUrl';
    }

    // Follow final redirect to establish session
    final systemResponse = await _getFollow(redirectUrl);
    final finalUri = systemResponse.realUri;

    // Discover actual base URL from redirect
    final discoveredBase = '${finalUri.scheme}://${finalUri.host}'
        '${finalUri.hasPort ? ":${finalUri.port}" : ""}';

    // Prefer the real domain the portal redirected us to.
    // The month-based guess is only a fallback when discovery lands on SEP
    // itself (i.e. the redirect chain did not leave the portal, meaning the
    // session was not established on any course system).
    // 2026-09 抓包实证: 9月门户仍指向 xkgo:3000，按月猜测会错选 xkgodj。
    debugPrint('[XKGO] discovered base: $discoveredBase');
    if (!discoveredBase.contains('sep.ucas.ac.cn')) {
      _dynamicBaseUrl = discoveredBase;
    } else {
      debugPrint('[XKGO] discovery stayed on SEP portal, falling back');
      _dynamicBaseUrl ??= _getCurrentXkgoBase();
    }

    // Force access to schedule page to finalize session
    await _getFollow('$baseUrl$_schedulePath');
  }

  /// Find portal link in menu HTML
  String? _findPortalLink(
    String html, {
    List<String> keywords = const ['选课', '我的课程'],
  }) {
    final document = html_parser.parse(html);
    final links = document.querySelectorAll('a');

    for (final link in links) {
      final text = link.text.trim();
      if (text.isEmpty) continue;

      final hasKeyword = keywords.any((keyword) => text.contains(keyword));
      if (!hasKeyword) continue;

      var href = link.attributes['href'];
      if (href == null) continue;

      if (href.startsWith('/')) {
        href = '$_sepBaseUrl$href';
      }

      return href;
    }

    return null;
  }

  /// Extract redirect URL from HTML
  String? _extractRedirectUrl(String html) {
    final metaMatch = RegExp(
      r'url=([^">]+)',
      caseSensitive: false,
    ).firstMatch(html);

    if (metaMatch != null) {
      return metaMatch.group(1)?.trim();
    }

    var jsMatch = RegExp(r'location\.href\s*=\s*"([^"]+)"').firstMatch(html);
    jsMatch ??= RegExp(r"location\.href\s*=\s*'([^']+)'").firstMatch(html);

    if (jsMatch != null) {
      return jsMatch.group(1)?.trim();
    }

    return null;
  }

  /// Get text content from URL
  Future<String> _getText(String url) async {
    final response = await _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    return response.data ?? '';
  }

  /// Follow redirects manually
  Future<Response<String>> _getFollow(String url, {Options? options}) async {
    var current = Uri.parse(url);
    final requestOptions = options ?? Options();
    requestOptions.followRedirects = false;
    requestOptions.responseType = ResponseType.plain;
    requestOptions.validateStatus = (status) => status != null && status < 500;

    for (var i = 0; i < 6; i++) {
      final response = await _dio.get<String>(
        current.toString(),
        options: requestOptions,
      );

      if (response.statusCode != null &&
          response.statusCode! >= 300 &&
          response.statusCode! < 400) {
        final location = response.headers.value('location');
        if (location == null) {
          throw Exception('Redirect missing Location header');
        }
        current = current.resolve(location);
        continue;
      }

      return response;
    }

    throw Exception('Too many redirects');
  }

  /// Reset dynamic URL (for testing or seasonal changes)
  void resetDynamicUrl() {
    _dynamicBaseUrl = null;
  }
}
