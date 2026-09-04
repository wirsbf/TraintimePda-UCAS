import 'dart:io';

import 'package:dio/dio.dart';
import 'package:encrypter_plus/encrypter_plus.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:pointycastle/asymmetric/api.dart';
import 'package:flutter/foundation.dart';

import '../captcha_ocr.dart';

import 'authentication_service.dart';
import 'session_manager.dart';

/// SEP system authentication service
/// 
/// Handles login to UCAS Unified Authentication Platform (SEP)
/// with RSA password encryption and captcha support.
class SepAuthenticationService implements AuthenticationService {
  SepAuthenticationService({required Dio dio}) : _dio = dio;

  final Dio _dio;

  @override
  SessionType get type => SessionType.sep;

  @override
  String get baseUrl => type.baseUrl;

  static const String _loginPath = '/slogin';
  static const String _captchaPath = '/changePic';
  static const String _validationPath = '/portal/site/226/821';

  @override
  Future<AuthResult> authenticate(Credentials credentials) async {
    // Early return if already logged in
    if (await validateSession()) {
      final cookies = await _getCookies();
      return AuthResult.success(cookies);
    }

    final loginPage = await _fetchLoginPage();
    final context = _parseLoginContext(loginPage);

    // Handle captcha requirement with auto-OCR
    String? captchaCode = credentials.captchaCode;
    if (context.captchaRequired && captchaCode == null) {
      final captchaImage = await _fetchCaptchaImage();
      
      // Try OCR recognition first (max 3 attempts)
      for (int attempt = 1; attempt <= 3; attempt++) {
        final ocrResult = await CaptchaOcr.instance.solveCaptcha(captchaImage);
        if (ocrResult != null && ocrResult.length >= 4) {
          captchaCode = ocrResult;
          debugPrint('[SEP Auth] OCR succeeded on attempt $attempt: $captchaCode');
          break;
        }
        debugPrint('[SEP Auth] OCR attempt $attempt failed');
        
        // Fetch new captcha for next attempt
        if (attempt < 3) {
          await Future.delayed(const Duration(milliseconds: 300));
          final newCaptcha = await _fetchCaptchaImage();
          captchaImage.setAll(0, newCaptcha);
        }
      }
      
      // If OCR failed after 3 attempts, require manual input
      if (captchaCode == null) {
        debugPrint('[SEP Auth] OCR failed 3 times, requesting manual input');
        return AuthResult.captchaRequired(captchaImage);
      }
    }

    final encryptedPassword = _encryptPassword(
      credentials.password,
      context.publicKey,
    );

    final loginResult = await _performLogin(
      username: credentials.username,
      encryptedPassword: encryptedPassword,
      captchaCode: captchaCode,
      loginFrom: context.loginFrom,
    );

    return loginResult;
  }

  @override
  Future<bool> validateSession() async {
    try {
      final response = await _dio.get<String>(
        '$baseUrl$_validationPath',
        options: Options(
          followRedirects: false,
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      // Redirect to login means session invalid
      // (SEP migrated some redirects from 302 to 303, accept both)
      if (response.statusCode == 302 || response.statusCode == 303) {
        final location = response.headers.value('location') ?? '';
        if (location.contains('loginFrom') || location.contains('slogin')) {
          return false;
        }
        return false;
      }

      // Login page content means session invalid
      final body = response.data ?? '';
      if (body.contains('jsePubKey')) {
        return false;
      }

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Fetch login page HTML
  Future<String> _fetchLoginPage() async {
    final response = await _dio.get<String>(
      baseUrl,
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    return response.data ?? '';
  }

  /// Fetch captcha image
  Future<Uint8List> _fetchCaptchaImage() async {
    final response = await _dio.get<List<int>>(
      '$baseUrl$_captchaPath',
      options: Options(
        responseType: ResponseType.bytes,
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    if (response.data == null) {
      throw Exception('Failed to fetch captcha image');
    }

    return Uint8List.fromList(response.data!);
  }

  /// Perform login request
  Future<AuthResult> _performLogin({
    required String username,
    required String encryptedPassword,
    required String? captchaCode,
    required String loginFrom,
  }) async {
    final params = {
      'userName': username,
      'pwd': encryptedPassword,
      'certCode': captchaCode ?? '',
      'loginFrom': loginFrom,
      'sb': 'sb',
    };

    final response = await _dio.post<String>(
      '$baseUrl$_loginPath',
      data: params,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.plain,
        headers: {'Origin': baseUrl, 'Referer': baseUrl},
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    final body = response.data ?? '';

    // Check for specific error messages (guard clauses)
    if (body.contains('用户名或密码错误') || body.contains('密码错误')) {
      return AuthResult.failure('用户名或密码错误');
    }

    if (body.contains('验证码错误')) {
      return AuthResult.failure('验证码错误');
    }

    // Device phone verification flow (POST /user/doUserVisitPhone).
    // SEP may challenge unrecognized devices with an SMS code; the app cannot
    // complete this flow, so tell the user to trust the device in a browser.
    if (body.contains('yzPhone') ||
        body.contains('doUserVisitPhone') ||
        body.contains('手机验证') ||
        body.contains('短信验证')) {
      return AuthResult.failure('触发设备短信验证：请先在浏览器登录一次 SEP 并勾选“信任此设备”，再回到 App 重试');
    }

    // Verify login success
    if (await validateSession()) {
      final cookies = await _getCookies();
      return AuthResult.success(cookies);
    }

    // Check if captcha is now required
    final newContext = _parseLoginContext(body);
    if (newContext.captchaRequired) {
      final captchaImage = await _fetchCaptchaImage();
      return AuthResult.captchaRequired(captchaImage);
    }

    // Generic failure
    final errorMessage = _extractErrorMessage(body) ?? '登录失败，请检查网络或重试';
    return AuthResult.failure(errorMessage);
  }

  /// Get current cookies
  Future<List<Cookie>> _getCookies() async {
    // This will be provided by SessionManager in actual usage
    // For now, return empty list (will be handled by client)
    return [];
  }

  /// Parse login context from HTML
  _LoginContext _parseLoginContext(String html) {
    var keyMatch = RegExp(r'jsePubKey\s*=\s*"([^"]+)"').firstMatch(html);
    keyMatch ??= RegExp(r"jsePubKey\s*=\s*'([^']+)'").firstMatch(html);

    if (keyMatch == null) {
      throw Exception('Failed to find SEP login public key');
    }

    final publicKey = keyMatch.group(1) ?? '';
    final document = html_parser.parse(html);
    final loginFromInput = document.querySelector('input[name="loginFrom"]');
    final loginFrom = loginFromInput?.attributes['value'] ?? '';
    
    final captchaInput = document.querySelector(
      'input#certCode1, input[name="certCode1"], input#certCode, input[name="certCode"]',
    );

    return _LoginContext(
      publicKey: publicKey,
      loginFrom: loginFrom,
      captchaRequired: captchaInput != null,
    );
  }

  /// Encrypt password using RSA public key
  String _encryptPassword(String password, String publicKey) {
    final chunks = <String>[];
    for (var i = 0; i < publicKey.length; i += 64) {
      final end = (i + 64).clamp(0, publicKey.length);
      chunks.add(publicKey.substring(i, end));
    }
    
    final pem = '-----BEGIN PUBLIC KEY-----\n${chunks.join('\n')}\n-----END PUBLIC KEY-----\n';
    final rsaKey = RSAKeyParser().parse(pem) as RSAPublicKey;
    return Encrypter(RSA(publicKey: rsaKey)).encrypt(password).base64;
  }

  /// Extract error message from HTML
  String? _extractErrorMessage(String html) {
    final document = html_parser.parse(html);
    
    // Try alert element
    final alert = document.querySelector('.alert');
    if (alert != null) {
      final text = alert.text.trim();
      if (text.isNotEmpty) return text;
    }

    // Try login error element
    final loginError = document.querySelector('#loginError');
    if (loginError != null) {
      final text = loginError.text.trim();
      if (text.isNotEmpty) return text;
    }

    // Search for common error keywords
    final text = document.body?.text ?? '';
    const keywords = [
      '用户名或密码错误',
      '用户名或密码不正确',
      '账号或密码错误',
      '密码错误',
      '验证码',
      '锁定',
    ];

    for (final keyword in keywords) {
      if (text.contains(keyword)) return keyword;
    }

    return null;
  }
}

/// Login context parsed from HTML
class _LoginContext {
  const _LoginContext({
    required this.publicKey,
    required this.loginFrom,
    required this.captchaRequired,
  });

  final String publicKey;
  final String loginFrom;
  final bool captchaRequired;
}
