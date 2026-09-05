import 'dart:io';
import 'dart:typed_data';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:dio/io.dart';

import 'auth/session_manager.dart';
import 'auth/authentication_service.dart';
import 'auth/sep_authentication_service.dart';
import 'auth/jwxk_authentication_service.dart';
import 'auth/xkgo_authentication_service.dart';
import 'services/schedule_service.dart';
import 'services/score_service.dart';
import 'services/exam_service.dart';
import 'services/lecture_service.dart';
import 'services/course_selection_service.dart';
import 'services/sep_portal_service.dart';

import '../model/schedule.dart';
import '../model/score.dart';
import '../model/exam.dart';
import '../model/lecture.dart';
import '../model/selected_course.dart';

/// Exception thrown when captcha is required for login
class CaptchaRequiredException implements Exception {
  const CaptchaRequiredException(this.image);
  final Uint8List image;

  @override
  String toString() => 'CaptchaRequiredException: Verification code required';
}

/// Exception thrown on authentication failure
class AuthException implements Exception {
  const AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Main UCAS client using Facade pattern
///
/// Provides unified API for all UCAS services (schedule, scores, exams, lectures).
/// Handles authentication, session management, and automatic retry on session expiration.
///
/// **Usage:**
/// ```dart
/// final client = UcasClient();
/// await client.initialize(username, password); // Pre-fetch all cookies
/// final schedule = await client.fetchSchedule(); // Uses cached session
/// ```
class UcasClient {
  UcasClient({Dio? dio})
      : _dio = dio ?? _createDefaultDio(),
        _cookieJar = CookieJar(),
        _sessionManager = SessionManager() {
    if (dio == null) {
      _dio.interceptors.add(CookieManager(_cookieJar));
      // SEP session guard + diagnostics. Runs AFTER the CookieManager, i.e.
      // at the actual send moment: if a known-good authenticated session
      // exists but the jar was churned by a late Set-Cookie response, the
      // Cookie header is rewritten to carry the good session. This closes
      // the microsecond race between pre-request checks and the send.
      _dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.host.contains('sep.ucas.ac.cn')) {
            final good = _sepAuth.knownGoodSession;
            final current = options.headers['Cookie'] as String? ?? '';
            debugPrint('[COOKIE] ${options.uri.path} <= ${current.isEmpty ? '(none)' : current}');
            if (good != null && !current.contains(good)) {
              options.headers['Cookie'] = 'JSESSIONID=$good';
              debugPrint('[COOKIE] guard rewrote header to known-good session');
            }
            // Remember what this request actually carries, so onResponse
            // can promote it to "known-good" when the server confirms it.
            options.extra['sentCookie'] = options.headers['Cookie'] as String? ?? '';
          }
          return handler.next(options);
        },
        onResponse: (response, handler) {
          final path = response.requestOptions.uri.path;
          final ok = response.statusCode == 200;
          if (ok && (path == '/portal/site/226/821' || path == '/slogin')) {
            final sent = response.requestOptions.extra['sentCookie'] as String? ?? '';
            final sid = RegExp(r'JSESSIONID=([A-Za-z0-9]+)')
                    .firstMatch(sent)
                    ?.group(1) ??
                '';
            _sepAuth.markKnownGoodSession(sid);
          }
          return handler.next(response);
        },
      ));
      _configureHttpClient();
    }

    // Initialize services with dependency injection
    _sepAuth = SepAuthenticationService(dio: _dio, cookieJar: _cookieJar);
    _jwxkAuth = JwxkAuthenticationService(dio: _dio, sepAuth: _sepAuth);
    _xkgoAuth = XkgoAuthenticationService(dio: _dio, sepAuth: _sepAuth);

    _scheduleService = ScheduleService(
      dio: _dio,
      xkgoAuth: _xkgoAuth,
      jwxkAuth: _jwxkAuth,
    );
    _scoreService = ScoreService(dio: _dio, jwxkAuth: _jwxkAuth);
    _examService = ExamService(dio: _dio, jwxkAuth: _jwxkAuth);
    _lectureService = LectureService(dio: _dio, jwxkAuth: _jwxkAuth);
    _courseSelectionService = CourseSelectionService(dio: _dio, xkgoAuth: _xkgoAuth);
    _sepPortalService = SepPortalService(dio: _dio, sepAuth: _sepAuth);
  }

  // Singleton instance
  static final instance = UcasClient();

  final Dio _dio;
  final CookieJar _cookieJar;
  final SessionManager _sessionManager;

  late final SepAuthenticationService _sepAuth;
  late final JwxkAuthenticationService _jwxkAuth;
  late final XkgoAuthenticationService _xkgoAuth;

  late final ScheduleService _scheduleService;
  late final ScoreService _scoreService;
  late final ExamService _examService;
  late final LectureService _lectureService;
  late final CourseSelectionService _courseSelectionService;
  late final SepPortalService _sepPortalService;

  String? _lastUsername;
  String? _lastPassword;

  // Single-flight auth lock: concurrent session-expired errors all funnel
  // into ONE re-authentication attempt (otherwise parallel fetches each
  // trigger their own login + captcha dialog and the dialogs stack up).
  final Map<AuthenticationService, Future<void>> _authFlights = {};

  // ========== Public API ==========

  /// Initialize client by pre-fetching all authentication cookies
  /// 
  /// Should be called once at application startup for best performance.
  /// All subsequent API calls will use cached sessions.
  Future<void> initialize(String username, String password) async {
    _lastUsername = username;
    _lastPassword = password;

    // Authenticate with all systems in parallel (after SEP)
    await _authenticateWithRetry(_sepAuth, Credentials(
      username: username,
      password: password,
    ));

    // Authenticate with all systems sequentially to avoid cookie race conditions
    await _authenticateWithRetry(_jwxkAuth, Credentials(
      username: username.contains('@') ? username : '$username@mails.ucas.ac.cn',
      password: password,
    ));

    await _authenticateWithRetry(_xkgoAuth, Credentials(
      username: username,
      password: password,
    ));
  }

  /// Login to SEP system (legacy API, prefer using initialize())
  Future<void> login(
    String username,
    String password, {
    String? captchaCode,
  }) async {
    _lastUsername = username;
    _lastPassword = password;

    await _authenticateWithRetry(
      _sepAuth,
      Credentials(
        username: username,
        password: password,
        captchaCode: captchaCode,
      ),
    );
  }

  /// Manually set session ID for XKGO system (for testing/debugging)
  Future<void> setSessionId(String sessionId) async {
    final cookie = Cookie('session_id', sessionId);
    await _cookieJar.saveFromResponse(
      Uri.parse(_xkgoAuth.baseUrl),
      [cookie],
    );
  }

  /// Manually set SEP JSESSIONID (for testing/debugging).
  /// Lets tooling reuse an already-authenticated browser session instead of
  /// solving the captcha interactively.
  Future<void> setSepSessionId(String jsessionId) async {
    final cookie = Cookie('JSESSIONID', jsessionId);
    await _cookieJar.saveFromResponse(
      Uri.parse('https://sep.ucas.ac.cn'),
      [cookie],
    );
  }

  /// Get cookies for a specific URL (for debugging)
  static Future<List<Cookie>> getCookies(String url) async {
    final cookieJar = CookieJar();
    return cookieJar.loadForRequest(Uri.parse(url));
  }

  /// Fetch personal schedule
  Future<Schedule> fetchSchedule([String? username, String? password]) async {
    if (username != null && password != null) {
      await initialize(username, password);
    }

    return await _executeWithAuth(
      authService: _xkgoAuth,
      action: () => _scheduleService.fetchSchedule(),
    );
  }

  /// Fetch all scores
  Future<List<Score>> fetchScores([String? username, String? password]) async {
    if (username != null && password != null) {
      final effectiveUsername = username.contains('@')
          ? username
          : '$username@mails.ucas.ac.cn';
      await initialize(effectiveUsername, password);
    }

    return await _executeWithAuth(
      authService: _jwxkAuth,
      action: () => _scoreService.fetchScores(),
    );
  }

  /// Fetch all exams
  Future<List<Exam>> fetchExams([String? username, String? password]) async {
    if (username != null && password != null) {
      final effectiveUsername = username.contains('@')
          ? username
          : '$username@mails.ucas.ac.cn';
      await initialize(effectiveUsername, password);
    }

    return await _executeWithAuth(
      authService: _jwxkAuth,
      action: () => _examService.fetchExams(),
    );
  }

  /// Fetch selected courses details for review
  Future<List<SelectedCourse>> fetchSelectedCoursesDetails() async {
    return await _executeWithAuth(
      authService: _xkgoAuth,
      action: () => _courseSelectionService.fetchSelectedCoursesDetails(),
    );
  }

  /// Fetch all lectures
  Future<List<Lecture>> fetchLectures([String? username, String? password]) async {
    if (username != null && password != null) {
      final effectiveUsername = username.contains('@')
          ? username
          : '$username@mails.ucas.ac.cn';
      await initialize(effectiveUsername, password);
    }

    return await _executeWithAuth(
      authService: _jwxkAuth,
      action: () => _lectureService.fetchLectures(),
    );
  }

  /// Fetch lecture detail
  Future<Map<String, String>> fetchLectureDetail(
    String path, {
    String? username,
    String? password,
  }) async {
    return await _lectureService.fetchLectureDetail(
      path,
      username: username ?? _lastUsername ?? '',
      password: password ?? _lastPassword ?? '',
    );
  }

  /// Search for courses (auto-robber feature)
  Future<String> searchCourse(String query, {bool isCode = false}) async {
    return await _executeWithAuth(
      authService: _xkgoAuth,
      action: () => _courseSelectionService.searchCourse(query, isCode: isCode),
    );
  }

  /// Get course selection captcha
  Future<Uint8List> getCourseSelectionCaptcha() async {
    return await _executeWithAuth(
      authService: _xkgoAuth,
      action: () => _courseSelectionService.getCaptcha(),
    );
  }

  /// Submit course selection
  Future<String> saveCourse(String sids, String vcode) async {
    return await _executeWithAuth(
      authService: _xkgoAuth,
      action: () => _courseSelectionService.saveCourse(sids, vcode),
    );
  }

  /// SEP 门户卡片数据（一卡通/学分/GPA/提醒/评教）
  SepPortalService get sepPortal => _sepPortalService;

  /// Fetch XKGO main page (exposed for debugging/parsing)
  Future<String> fetchXkgoMain() async {
    return await _executeWithAuth(
      authService: _xkgoAuth,
      action: () => _courseSelectionService.fetchMainPage(),
    );
  }

  // ========== Private Helper Methods ==========

  /// Execute action with automatic authentication retry on session expiration
  Future<T> _executeWithAuth<T>({
    required AuthenticationService authService,
    required Future<T> Function() action,
  }) async {
    try {
      return await action();
    } on SessionExpiredException {
      // Session expired - re-authenticate and retry
      if (_lastUsername == null || _lastPassword == null) {
        throw Exception('Session expired and no credentials available for re-authentication');
      }

      await _authenticateWithRetry(
        authService,
        Credentials(
          username: _lastUsername!,
          password: _lastPassword!,
        ),
      );

      return await action();
    } catch (e) {
      // Check if error message indicates session expiration
      if (e.toString().contains('session') || e.toString().contains('Session')) {
        if (_lastUsername == null || _lastPassword == null) {
          rethrow;
        }

        await _authenticateWithRetry(
          authService,
          Credentials(
            username: _lastUsername!,
            password: _lastPassword!,
          ),
        );

        return await action();
      }

      rethrow;
    }
  }

  /// Global auth serialization: the SEP portal only tolerates ONE active
  /// subsystem Identity flow at a time (concurrent flows invalidate each
  /// other server-side, cascading into captcha prompts). All
  /// authentications therefore run strictly one after another.
  Future<void>? _authChain;

  Future<T> _serializeAuth<T>(Future<T> Function() op) {
    final next = _authChain == null
        ? op()
        : _authChain!.then((_) => op(), onError: (_) => op());
    // Keep the chain alive regardless of individual failures.
    _authChain = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  /// Authenticate with retry logic (serialized globally, single-flight per
  /// service)
  Future<void> _authenticateWithRetry(
    AuthenticationService service,
    Credentials credentials, {
    int maxRetries = 3,
  }) {
    // Share one in-flight authentication across concurrent callers.
    final existing = _authFlights[service];
    if (existing != null) {
      return existing;
    }

    final flight = _serializeAuth(() => _authenticateWithRetryLocked(
          service,
          credentials,
          maxRetries: maxRetries,
        )).whenComplete(() {
      _authFlights.remove(service);
    });
    _authFlights[service] = flight;
    return flight;
  }

  Future<void> _authenticateWithRetryLocked(
    AuthenticationService service,
    Credentials credentials, {
    int maxRetries = 3,
  }) async {
    // Check cached session first
    final isValid = await _sessionManager.validateSession(
      service.type,
      validator: () => service.validateSession(),
    );

    if (isValid) return;

    // Re-authenticate with retry
    for (int i = 0; i < maxRetries; i++) {
      try {
        final result = await service.authenticate(credentials);

        if (result.success) {
          if (result.cookies != null && result.cookies!.isNotEmpty) {
            await _sessionManager.saveSession(service.type, result.cookies!);
          } else {
            // Auth succeeded without explicit cookies (e.g. SEP login via
            // the shared jar): force the next validation to re-check for
            // real instead of trusting the stale cached "false".
            _sessionManager.invalidateCache(service.type);
          }
          return;
        }

        if (result.captchaImage != null) {
          throw CaptchaRequiredException(result.captchaImage!);
        }

        throw AuthException(result.errorMessage ?? 'Authentication failed');
      } catch (e) {
        if (e is CaptchaRequiredException || e is AuthException) {
          rethrow;
        }

        if (i == maxRetries - 1) {
          rethrow;
        }

        // Exponential backoff
        await Future.delayed(Duration(milliseconds: 500 * (1 << i)));
      }
    }
  }

  /// Create default Dio instance
  static Dio _createDefaultDio() {
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 12),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
    ));
  }

  /// Configure HTTP client to bypass certificate validation
  void _configureHttpClient() {
    final adapter = _dio.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      adapter.createHttpClient = () {
        final client = HttpClient();
        client.findProxy = (_) => 'DIRECT';
        client.badCertificateCallback = (_, __, ___) => true;
        return client;
      };
    }
  }
}
