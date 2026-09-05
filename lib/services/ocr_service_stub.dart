import 'dart:typed_data';

/// Web stub for [OcrService]: dart:ffi-based ONNX OCR is unavailable on the
/// web platform, so captcha solving simply reports failure there.
class OcrService {
  Future<void> init() async {}
  Future<String> predict(Uint8List imageBytes, {String? allowedChars}) async {
    return '';
  }
  void dispose() {}
}
