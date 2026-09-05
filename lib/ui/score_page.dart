import 'package:flutter/material.dart';
import '../data/ucas_client.dart';
import '../model/score.dart';
import '../data/auth_gate.dart';
import '../data/cache_manager.dart';

class ScorePage extends StatefulWidget {
  const ScorePage({super.key});

  @override
  State<ScorePage> createState() => _ScorePageState();
}

class _ScorePageState extends State<ScorePage> {
  List<Score>? _scores;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCache();
    _fetchScores();
  }

  Future<void> _loadCache() async {
    final cached = await CacheManager().getScores();
    if (mounted && cached.isNotEmpty) {
      setState(() => _scores = cached);
    }
  }

  Future<void> _fetchScores() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Fetch scores using cached session (auto-retry if session expired)
      final scores = await UcasClient.instance.fetchScores();
      setState(() {
        _scores = scores;
      });
      await CacheManager().saveScores(scores);
    } on CaptchaRequiredException {
      // One coordinated captcha via the global gate; retry once.
      if (await AuthGate.instance.ensureLoggedIn()) {
        try {
          final scores = await UcasClient.instance.fetchScores();
          if (mounted) setState(() => _scores = scores);
          await CacheManager().saveScores(scores);
        } catch (_) {}
      } else if (mounted) {
        setState(() { _error = '验证码已取消'; });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('成绩查询'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _fetchScores,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _fetchScores, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_scores == null || _scores!.isEmpty) {
      return const Center(child: Text('暂无成绩记录'));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _scores!.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final score = _scores![index];
        return _ScoreCard(score: score);
      },
    );
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.score});

  final Score score;

  @override
  Widget build(BuildContext context) {
    final isPass =
        score.score == '通过' ||
        score.score == '优' ||
        score.score == '良' ||
        score.score.contains('免修') ||
        (double.tryParse(score.score) ?? 60) >= 60;

    final isDegree = score.isDegree.contains('是');

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDegree
              ? Colors.orange.shade200
              : Colors.grey.shade200, // Highlight degree courses
          width: isDegree ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      score.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E293B),
                        height: 1.2,
                      ),
                    ),
                    if (score.englishName.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        score.englishName,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    score.score,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isPass
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                    ),
                  ),
                  if (score.evaluation.isNotEmpty)
                    Text(
                      score.evaluation,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildTag(
                '学分: ${score.credit}',
                Colors.blue.shade50,
                Colors.blue.shade700,
              ),
              if (isDegree)
                _buildTag('学位课', Colors.orange.shade50, Colors.orange.shade800),

              _buildTag(
                score.semester,
                Colors.grey.shade100,
                Colors.grey.shade700,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTag(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w500),
      ),
    );
  }
}
