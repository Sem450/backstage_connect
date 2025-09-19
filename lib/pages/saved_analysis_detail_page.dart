// lib/pages/saved_analysis_detail_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/risk_face.dart';

class SavedAnalysisDetailPage extends StatelessWidget {
  final Map<String, dynamic> analysisRow;
  const SavedAnalysisDetailPage({super.key, required this.analysisRow});

  List<Map<String, dynamic>> _coerceListOfMap(dynamic v, List<String> keys) {
    if (v is! List) return [];
    return v.map<Map<String, dynamic>>((e) {
      if (e is Map) {
        final m = Map<String, dynamic>.from(e);
        final out = <String, dynamic>{};
        for (final k in keys) {
          out[k] = (m[k] ?? '').toString();
        }
        return out;
      }
      return {keys.first: e.toString()};
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final data = Map<String, dynamic>.from(analysisRow['analysis_json'] ?? {});
    final title = (analysisRow['title'] ?? 'Contract analysis').toString();

    final summary = (data['summary'] ?? '').toString();
    final pros = _coerceListOfMap(data['pros'], ['title', 'why_it_matters']);
    final cons = _coerceListOfMap(data['cons'], ['title', 'why_it_matters']);
    final redFlags = _coerceListOfMap(
      data['red_flags'],
      ['clause', 'severity', 'explanation', 'suggested_language', 'source_excerpt'],
    );
    final score = (data['risk_score'] is num) ? (data['risk_score'] as num).toDouble() : 70.0;
    final label = ((data['risk_label'] ?? '') as String).trim();

    const bg = Color(0xFFF5F6FA); // page
    const card = Colors.white;     // cards
    const border = Color(0xFFE6E8EF);
    const textPrimary = Color(0xFF111827);
    const textSecondary = Color(0xFF6B7280);
    const accent = Color(0xFF6C63FF);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        backgroundColor: Colors.white,
        elevation: 0.5,
        surfaceTintColor: Colors.transparent,
        foregroundColor: textPrimary,
        title: Text(
          title,
          style: const TextStyle(
            color: textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: const IconThemeData(color: textPrimary),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Score / Face
            Center(
              child: RiskFace(
                score: score,
                label: label.isEmpty ? null : label,
                size: 160,
              ),
            ),

            const SizedBox(height: 16),

            if (summary.isNotEmpty)
              _sectionCard(
                title: 'Summary',
                child: Text(
                  summary,
                  style: const TextStyle(color: textSecondary, height: 1.4),
                ),
                card: card,
                border: border,
                titleColor: textPrimary,
              ),

            if (pros.isNotEmpty || cons.isNotEmpty)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (pros.isNotEmpty)
                    Expanded(
                      child: _sectionCard(
                        title: 'Pros',
                        child: _bullets(
                          items: pros,
                          positive: true,
                          titleColor: textPrimary,
                          bodyColor: textSecondary,
                        ),
                        card: card,
                        border: border,
                        titleColor: textPrimary,
                      ),
                    ),
                  if (pros.isNotEmpty && cons.isNotEmpty) const SizedBox(width: 12),
                  if (cons.isNotEmpty)
                    Expanded(
                      child: _sectionCard(
                        title: 'Cons',
                        child: _bullets(
                          items: cons,
                          positive: false,
                          titleColor: textPrimary,
                          bodyColor: textSecondary,
                        ),
                        card: card,
                        border: border,
                        titleColor: textPrimary,
                      ),
                    ),
                ],
              ),

            if (redFlags.isNotEmpty)
              _sectionCard(
                title: 'Risks / red flags',
                child: Column(
                  children: redFlags.map((f) {
                    final clause = (f['clause'] ?? '').toString();
                    final why = (f['explanation'] ?? '').toString();
                    final source = (f['source_excerpt'] ?? '').toString();

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF1F2), // light red tint
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            clause.isEmpty ? 'Clause' : clause,
                            style: const TextStyle(
                              color: Color(0xFF991B1B),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (source.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              '“$source”',
                              style: const TextStyle(
                                color: Color(0xFFB91C1C),
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                          if (why.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              why,
                              style: const TextStyle(color: Color(0xFF7F1D1D)),
                            ),
                          ],
                        ],
                      ),
                    );
                  }).toList(),
                ),
                card: card,
                border: border,
                titleColor: textPrimary,
              ),
          ],
        ),
      ),
    );
  }

  // ---- UI helpers -----------------------------------------------------------

  Widget _sectionCard({
    required String title,
    required Widget child,
    required Color card,
    required Color border,
    required Color titleColor,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(color: titleColor, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _bullets({
    required List<Map<String, dynamic>> items,
    required bool positive,
    required Color titleColor,
    required Color bodyColor,
  }) {
    final iconColor = positive ? const Color(0xFF16A34A) : const Color(0xFFB45309);
    final iconData =
        positive ? Icons.check_circle_outline : Icons.warning_amber_outlined;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items.map((m) {
        final t = (m['title'] ?? '').toString();
        final why = (m['why_it_matters'] ?? '').toString();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(iconData, size: 20, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t,
                      style: TextStyle(color: titleColor, fontWeight: FontWeight.w700),
                    ),
                    if (why.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          why,
                          style: TextStyle(color: bodyColor, height: 1.35),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
