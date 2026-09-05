import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/ucas_client.dart';
import '../model/sep_portal.dart';

/// 课程/教师评估页（数据来自 xkcts 选课系统）
///
/// 「一键评教」说明：评估表单仅在评教窗口开放且存在未评估课程时可见，
/// 服务端表单结构需要实际观察后才能实现自动提交。当前版本提供
/// 评估状态总览 + 一键直达评估页（系统浏览器打开，自动带登录态）。
class EvaluationPage extends StatefulWidget {
  const EvaluationPage({super.key});

  @override
  State<EvaluationPage> createState() => _EvaluationPageState();
}

class _EvaluationPageState extends State<EvaluationPage> {
  bool _loading = true;
  String? _error;
  Map<String, String> _terms = {};
  String? _selectedTerm;
  final Map<String, List<EvalCourse>> _cache = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _terms = await UcasClient.instance.sepPortal.establishEvaluationSession();
      if (_terms.isEmpty) {
        _error = '当前没有可评估的学期';
      } else {
        _selectedTerm = _terms.keys.first;
        await _loadTerm(_selectedTerm!);
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadTerm(String termId) async {
    if (_cache.containsKey('c$termId')) return;
    final portal = UcasClient.instance.sepPortal;
    _cache['c$termId'] = await portal.fetchEvaluationCourses(termId: termId);
    _cache['t$termId'] =
        await portal.fetchEvaluationCourses(termId: termId, type: 'teacher');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('教学评估')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _buildList(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(_error!, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          FilledButton(onPressed: _init, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildList() {
    final courses = _cache['c$_selectedTerm'] ?? const [];
    final teachers = _cache['t$_selectedTerm'] ?? const [];
    final pending =
        courses.where((c) => !c.evaluated).length + teachers.where((c) => !c.evaluated).length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_terms.length > 1)
          DropdownButtonFormField<String>(
            initialValue: _selectedTerm,
            decoration: const InputDecoration(
                labelText: '学期', border: OutlineInputBorder()),
            items: _terms.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: (v) async {
              if (v == null) return;
              setState(() { _selectedTerm = v; _loading = true; });
              await _loadTerm(v);
              if (mounted) setState(() => _loading = false);
            },
          ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: Icon(
              pending == 0 ? Icons.check_circle : Icons.pending_actions,
              color: pending == 0 ? Colors.green : Colors.orange,
            ),
            title: Text(pending == 0 ? '全部评估完成' : '$pending 项待评估'),
            subtitle: Text(
                '课程评估 ${courses.where((c) => !c.evaluated).length} 门 · '
                '教师评估 ${teachers.where((c) => !c.evaluated).length} 条'),
            trailing: pending > 0
                ? FilledButton(
                    onPressed: () => _openPending(courses, teachers),
                    child: const Text('去评估'),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 8),
        ...courses.map((c) => _evalTile(c, '课程评估')),
        ...teachers.map((c) => _evalTile(c, '教师评估')),
      ],
    );
  }

  Widget _evalTile(EvalCourse c, String type) {
    return ListTile(
      dense: true,
      leading: Icon(
        c.evaluated ? Icons.check : Icons.radio_button_unchecked,
        color: c.evaluated ? Colors.green : Colors.orange,
        size: 20,
      ),
      title: Text('${c.name}', style: const TextStyle(fontSize: 14),
          overflow: TextOverflow.ellipsis),
      subtitle: Text('$type · ${c.teacher}', style: const TextStyle(fontSize: 12)),
      trailing: !c.evaluated && c.actionUrl != null
          ? IconButton(
              icon: const Icon(Icons.open_in_new, size: 18),
              onPressed: () => _launch(c.actionUrl!),
            )
          : null,
    );
  }

  Future<void> _openPending(List<EvalCourse> courses, List<EvalCourse> teachers) async {
    final pending = [...courses, ...teachers].where((c) => !c.evaluated).toList();
    if (pending.isEmpty) return;
    // 打开第一个待评估项
    await _launch(pending.first.actionUrl ?? '');
  }

  Future<void> _launch(String pathOrUrl) async {
    if (pathOrUrl.isEmpty) return;
    final url = UcasClient.instance.sepPortal.resolveActionUrl(pathOrUrl);
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开: $url')),
      );
    }
  }
}
