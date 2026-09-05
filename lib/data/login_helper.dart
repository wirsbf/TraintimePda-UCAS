import 'package:flutter/foundation.dart';
import 'ucas_client.dart';

/// Helper class for login operations with manual captcha input.
///
/// Auto-OCR was removed: the ONNX model misread SEP captchas and its retry
/// loop refreshed the captcha image several times per login, which kept
/// invalidating the image shown to the user.
class LoginHelper {
  static const int maxManualAttempts = 3;

  final UcasClient _client;

  /// IMPORTANT: always default to the app-wide singleton. Creating a fresh
  /// [UcasClient] here used to log in inside a throwaway CookieJar, so the
  /// session never reached the pages' client and everything re-authed.
  LoginHelper({UcasClient? client}) : _client = client ?? UcasClient.instance;

  /// Attempts to login, asking the user to type the captcha when required.
  ///
  /// Returns:
  /// - `null` if login succeeded
  /// - `Uint8List` (last captcha image) if manual input was cancelled or
  ///   all attempts failed
  Future<Uint8List?> loginWithManualCaptcha(
    String username,
    String password, {
    Future<String?> Function(Uint8List image)? onManualCaptchaNeeded,
  }) async {
    // First attempt without captcha (in case it is not required)
    Uint8List? currentImage;
    try {
      await _client.login(username, password);
      return null; // Success
    } on CaptchaRequiredException catch (e) {
      currentImage = e.image;
    }

    for (int attempt = 1; attempt <= maxManualAttempts; attempt++) {
      if (onManualCaptchaNeeded == null || currentImage == null) {
        return currentImage;
      }
      final code = await onManualCaptchaNeeded(currentImage);
      if (code == null || code.isEmpty) {
        debugPrint('[LoginHelper] Manual captcha cancelled');
        return currentImage; // User cancelled
      }

      try {
        await _client.login(username, password, captchaCode: code);
        debugPrint('[LoginHelper] Login successful with manual captcha');
        return null; // Success
      } on CaptchaRequiredException catch (e) {
        // Server replied with a fresh captcha page — retry with the new image
        debugPrint('[LoginHelper] Captcha incorrect (attempt $attempt), retrying with new image');
        currentImage = e.image;
      } on AuthException catch (e) {
        if (!e.message.contains('验证码')) rethrow;
        // Explicit "验证码错误" page: fetch a fresh image for the next round
        debugPrint('[LoginHelper] Captcha rejected (attempt $attempt), fetching new image');
        try {
          await _client.login(username, password);
        } on CaptchaRequiredException catch (e) {
          currentImage = e.image;
        }
      }
    }

    debugPrint('[LoginHelper] All $maxManualAttempts manual attempts failed');
    return currentImage;
  }
}
