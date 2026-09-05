import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Captcha input dialog (manual input only — OCR prefill removed).
Future<String?> showCaptchaDialog(BuildContext context, Uint8List image) {
  final codeController = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('请输入验证码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.memory(image, height: 60),
          const SizedBox(height: 16),
          TextField(
            controller: codeController,
            autofocus: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '验证码',
            ),
            onSubmitted: (val) {
              if (val.trim().isNotEmpty) {
                Navigator.pop(context, val.trim());
              }
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (codeController.text.trim().isNotEmpty) {
              Navigator.pop(context, codeController.text.trim());
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
