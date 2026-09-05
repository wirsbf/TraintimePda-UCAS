import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import 'authentication_service.dart';
import 'session_manager.dart';
import 'sep_authentication_service.dart';

/// JWXK system authentication service
/// 
/// Handles login to UCAS Course Management System (JWXK).
/// Requires prior SEP authentication to obtain Identity token.
class JwxkAuthenticationService implements AuthenticationService {
  JwxkAuthenticationService({
    required Dio dio,
    required SepAuthenticationService sepAuth,
  })  : _dio = dio,
        _sepAuth = sepAuth;

  final Dio _dio;
  final SepAuthenticationService _sepAuth;

  @override
  SessionType get type => SessionType.jwxk;

  @override
  String get baseUrl => type.baseUrl;

  static const String _sepBaseUrl = 'https://sep.ucas.ac.cn';
  static const String _menuPath = '/businessMenu';
  static const String _loginPath = '/login';

  // XOR key for encoding toUrl parameter (extracted from known plaintext)
  static const List<int> _xorKey = [
    0xa8, 0xda, 0x0d, 0x67, 0x2e, 0xc1, 0xb5, 0x8b,
    0xe5, 0x88, 0x7a, 0xfa, 0xc3, 0xfd, 0x5b, 0xe5,
    0xdb, 0xde, 0x76, 0xbd, 0xc9, 0xcd, 0xd7, 0x0b,
    0x89, 0x6f, 0x7e, 0x13, 0x64, 0x48, 0x62, 0x75,
    0xf5, 0xe2, 0xd1, 0x50, 0x41, 0x0c, 0xb0, 0xaa,
  ];

  @override
  Future<AuthResult> authenticate(Credentials credentials) async {
    // Ensure SEP login first
    final sepResult = await _sepAuth.authenticate(credentials);
    if (!sepResult.success) {
      return sepResult; // Forward SEP errors (including captcha)
    }

    // Get Identity token from portal
    final identity = await _getPortalIdentity();
    debugPrint('[JWXK] identity from portal: ${identity == null ? "NULL" : identity.substring(0, 8)}');
    if (identity == null) {
      return AuthResult.failure('Failed to obtain Identity token from SEP portal');
    }

    // Perform JWXK login
    final targetPath = '/courseManage/selectedCourse';
    final encodedToUrl = _encodeToUrl(targetPath);
    final jwxkLoginUrl = '$baseUrl$_loginPath?Identity=$identity&roleId=xs&fromUrl=1&toUrl=$encodedToUrl';

    try {
      final resp = await _getFollow(jwxkLoginUrl);
      debugPrint('[JWXK] login chain landed: ${resp.realUri} (${resp.statusCode})');
      
      // Verify login success
      if (await validateSession()) {
        debugPrint('[JWXK] session VALID');
        return AuthResult.success([]);
      }
      
      debugPrint('[JWXK] session INVALID after login');
      return AuthResult.failure('JWXK login failed: session not established');
    } catch (e) {
      debugPrint('[JWXK] login error: $e');
      return AuthResult.failure('JWXK login error: $e');
    }
  }

  @override
  Future<bool> validateSession() async {
    try {
      // Try accessing a protected page
      final response = await _dio.get<String>(
        '$baseUrl/courseManage/selectedCourse',
        options: Options(
          followRedirects: false,
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      // Check if we get redirected to login (session invalid)
      if (response.statusCode == 302) {
        final location = response.headers.value('location') ?? '';
        if (location.contains('login') || location.contains('Identity')) {
          return false;
        }
      }

      // Check if response contains login indicators
      final body = response.data ?? '';
      if (body.contains('Identity') && body.contains('login')) {
        return false;
      }

      // If we got actual content, session is valid
      return response.statusCode == 200 && body.contains('已选择的课程');
    } catch (_) {
      return false;
    }
  }

  /// Get Identity token from SEP portal
  Future<String?> _getPortalIdentity() async {
    final menuHtml = await _getText('$_sepBaseUrl$_menuPath');
    final portalUrl = _findPortalLink(menuHtml);

    if (portalUrl == null) return null;

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

    if (redirectUrl == null) return null;

    final identityMatch = RegExp(r'Identity=([^&]+)').firstMatch(redirectUrl);
    return identityMatch?.group(1);
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

  /// Extract redirect URL from HTML meta tag or JavaScript
  String? _extractRedirectUrl(String html) {
    final metaMatch = RegExp(
      r'url=([^">]+)',
      caseSensitive: false,
    ).firstMatch(html);

    if (metaMatch != null) {
      return metaMatch.group(1)?.trim();
    }

    final jsMatch = RegExp(
      r'location\.href\s*=\s*"([^"]+)"' ,
    ).firstMatch(html);

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

  /// Encode target path using XOR encryption
  String _encodeToUrl(String path) {
    final bytes = path.codeUnits;
    final encoded = <int>[];
    
    for (int i = 0; i < bytes.length; i++) {
      encoded.add(bytes[i] ^ _xorKey[i % _xorKey.length]);
    }
    
    return encoded
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join('');
  }
}
