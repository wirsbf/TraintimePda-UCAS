import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/services/sep_portal_service.dart';
import '../data/ucas_client.dart';
import '../util/open_url_helper.dart';

/// 公告详情页：标题 + 发布信息 + 正文（HTML 转段落文本）
class BulletinDetailPage extends StatefulWidget {
  const BulletinDetailPage({
    super.key,
    required this.bulletinId,
    required this.fallbackTitle,
    required this.department,
    required this.time,
  });

  final dynamic bulletinId;
  final String fallbackTitle;
  final String department;
  final String time;

  @override
  State<BulletinDetailPage> createState() => _BulletinDetailPageState();
}

class _BulletinDetailPageState extends State<BulletinDetailPage> {
  bool _loading = true;
  String? _error;
  String _title = '';
  String _publisher = '';
  String _time = '';
  String _noticeUrl = '';
  List<String> _paragraphs = const [];

  @override
  void initState() {
    super.initState();
    _title = widget.fallbackTitle;
    _publisher = widget.department;
    _time = widget.time;
    _load();
  }

  Future<void> _load() async {
    try {
      final detail =
          await UcasClient.instance.sepPortal.fetchBulletinDetail(widget.bulletinId);
      if (!mounted) return;
      setState(() {
        _title = '${detail['fileName'] ?? detail['title'] ?? _title}';
        _publisher = '${detail['publishUser'] ?? _publisher}';
        _time = '${detail['publishTime'] ?? _time}';
        _noticeUrl = '${detail['noticeUrl'] ?? ''}';
        _paragraphs = _htmlToParagraphs('${detail['content'] ?? ''}');
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  /// 将 Word 导出风格的 HTML 转成段落文本
  List<String> _htmlToParagraphs(String html) {
    if (html.isEmpty) return const [];
    var text = html
        .replaceAll(RegExp(r'<(script|style)[\s\S]*?</\1>'), '')
        .replaceAll('</p>', '\n\n')
        .replaceAll('<br/>', '\n')
        .replaceAll('<br>', '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');

    // HTML 实体
    const entities = {
      '&nbsp;': ' ', '&lt;': '<', '&gt;': '>', '&amp;': '&',
      '&quot;': '"', '&#39;': "'", '&ldquo;': '“', '&rdquo;': '”',
    };
    for (final e in entities.entries) {
      text = text.replaceAll(e.key, e.value);
    }

    return text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知公告'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            tooltip: '复制全文',
            onPressed: () {
              Clipboard.setData(ClipboardData(
                  text: '$_title\n$_publisher $_time\n\n${_paragraphs.join('\n')}'));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
              );
            },
          ),
          if (_noticeUrl.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 20),
              tooltip: '打开原文',
              onPressed: () => OpenUrlHelper.open(
                  context, 'https://sep.ucas.ac.cn$_noticeUrl', _title),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_error!, style: const TextStyle(color: Colors.grey)),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _load, child: const Text('重试')),
                  ],
                ))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(_title,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold, height: 1.4)),
                    const SizedBox(height: 8),
                    Text('$_publisher · $_time',
                        style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                    const Divider(height: 24),
                    ..._paragraphs.map((p) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(p,
                              style: const TextStyle(
                                  fontSize: 14, height: 1.6)),
                        )),
                  ],
                ),
    );
  }
}
