import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'login_helper.dart';
import '../ui/captcha_dialog.dart';

/// Global coordinator for login + captcha input.
///
/// Problem it solves: every page used to catch `CaptchaRequiredException`
/// and pop its own dialog, so one app-resume could stack several captcha
/// dialogs. Worse, subsystem (jwxk/xkgo) logins invalidate the SEP session
/// server-side, so chained re-auths kept demanding new captchas.
///
/// Rules:
/// - At most ONE login/captcha flow runs at a time; concurrent callers
///   await and share its result.
/// - After a successful solve, further requests within [solveTrust] reuse
///   the result without another dialog.
/// - After a cancel/failure, requests within [cancelCooldown] fail fast
///   and fall back to cached data instead of nagging the user.
class AuthGate {
  AuthGate._();
  static final AuthGate instance = AuthGate._();

  /// Attach to MaterialApp(navigatorKey: AuthGate.instance.navigatorKey)
  /// so the gate can show dialogs without a page context.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  String? _username;
  String? _password;
  Future<bool>? _inFlight;
  DateTime _lastSuccess = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastCancel = DateTime.fromMillisecondsSinceEpoch(0);

  /// Trust window after a successful captcha solve: the session was just
  /// rebuilt; do not ask the user again within this period even if a
  /// subsystem login invalidated it again server-side.
  static const Duration solveTrust = Duration(minutes: 10);

  /// After a cancel or exhausted retries, stop nagging for this long.
  static const Duration cancelCooldown = Duration(minutes: 2);

  bool get recentlySolved =>
      DateTime.now().difference(_lastSuccess) < solveTrust;

  bool get recentlyCancelled =>
      DateTime.now().difference(_lastCancel) < cancelCooldown;

  /// Store credentials for silent re-login (call at app start / settings
  /// change).
  void configure(String username, String password) {
    _username = username;
    _password = password;
  }

  /// Ensure a logged-in state, asking the user for a captcha when needed.
  ///
  /// Returns true when a login (possibly using an existing valid session)
  /// succeeded. Returns false when the user cancelled, retries exhausted,
  /// or we are in the cancel cooldown; callers should fall back to cache.
  Future<bool> ensureLoggedIn() {
    if (recentlySolved) return Future.value(true);
    if (recentlyCancelled) return Future.value(false);

    final existing = _inFlight;
    if (existing != null) return existing;

    final flight = _run().whenComplete(() => _inFlight = null);
    _inFlight = flight;
    return flight;
  }

  Future<bool> _run() async {
    final username = _username;
    final password = _password;
    if (username == null || username.isEmpty || password == null) {
      debugPrint('[AuthGate] no credentials configured');
      return false;
    }

    final result = await LoginHelper().loginWithManualCaptcha(
      username,
      password,
      onManualCaptchaNeeded: _showDialog,
    );

    if (result == null) {
      debugPrint('[AuthGate] login OK (session rebuilt or still valid)');
      _lastSuccess = DateTime.now();
      return true;
    }

    debugPrint('[AuthGate] login not completed; entering cancel cooldown');
    _lastCancel = DateTime.now();
    return false;
  }

  Future<String?> _showDialog(Uint8List image) async {
    // The navigator can be locked during startup route assembly (splash
    // mounting, page transitions). Retrying until it is idle avoids the
    // "!navigator._debugLocked" assertion crash.
    for (var attempt = 0; attempt < 20; attempt++) {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        try {
          await WidgetsBinding.instance.endOfFrame;
          return await showCaptchaDialog(ctx, image);
        } on FlutterError catch (e) {
          debugPrint('[AuthGate] navigator busy, retrying: $e');
        }
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    debugPrint('[AuthGate] could not show captcha dialog (navigator busy)');
    return null;
  }
}
