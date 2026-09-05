import 'package:flutter/foundation.dart';
// dart:ffi-based ONNX OCR is native-only; web gets a failing stub.
import '../services/ocr_service_stub.dart'
    if (dart.library.io) '../services/ocr_service.dart';

/// Unified captcha OCR service that selects implementation based on platform.
/// - Desktop (Windows, Linux, macOS): Uses Rust OCR (ddddocr)
/// - Mobile (Android): Uses custom trained ONNX CRNN model
/// - iOS: Uses Rust OCR (static linking) - may need separate handling if issues arise
class CaptchaOcr {
  static CaptchaOcr? _instance;
  static CaptchaOcr get instance {
    _instance ??= CaptchaOcr._();
    return _instance!;
  }

  CaptchaOcr._();

  String? _lastError;
  String? get lastError => _lastError;

  OcrService? _onnxService;

  /// Solve captcha from image bytes.
  /// Returns the recognized text, or null if recognition failed.
  /// [allowedChars] if provided, restricts the output to these characters.
  Future<String?> solveCaptcha(Uint8List imageBytes, {String? allowedChars}) async {
    _lastError = null;
    // Unified ONNX implementation for ALL platforms
    return _solveCaptchaWithOnnx(imageBytes, allowedChars: allowedChars);
  }

  /* 
  /// Legacy Rust OCR (Removed)
  String? _solveCaptchaWithRust(Uint8List imageBytes) { ... }
  */

  /// Use custom trained ONNX CRNN model (now ddddocr) for ALL platforms.
  Future<String?> _solveCaptchaWithOnnx(Uint8List imageBytes, {String? allowedChars}) async {
    try {
      // Initialize service if needed
      _onnxService ??= OcrService();
      await _onnxService!.init();

      final result = await _onnxService!.predict(imageBytes, allowedChars: allowedChars);
      
      if (result.isEmpty || result == "Error") {
        _lastError = 'ONNX model returned empty or error';
        return null;
      }

      debugPrint('[CaptchaOcr] ONNX recognized: $result');
      return result;
    } catch (e) {
      _lastError = 'ONNX exception: $e';
      debugPrint('[CaptchaOcr] ONNX error: $e');
      return null;
    }
  }

  /// Dispose resources.
  void dispose() {
    _onnxService?.dispose();
    _onnxService = null;
  }
}

