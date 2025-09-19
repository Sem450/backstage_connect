import 'package:flutter/material.dart';

enum RiskMood { good, meh, bad }

class RiskFace extends StatelessWidget {
  /// 0–100 risk score
  final double score;

  /// e.g. "Caution (needs changes)". If null/empty, we’ll derive from score.
  final String? label;

  /// Face diameter in px
  final double size;

  /// Show the label + "Risk score: X"
  final bool showCaption;

  const RiskFace({
    super.key,
    required this.score,
    this.label,
    this.size = 160,
    this.showCaption = true,
  });

  RiskMood _mood() {
    final s = score.clamp(0, 100).toDouble();
    if (s >= 70) return RiskMood.good;
    if (s >= 55) return RiskMood.meh;
    return RiskMood.bad;
  }

  String _defaultLabel(double s) {
    if (s >= 85) return 'Safe to sign';
    if (s >= 70) return 'Mostly OK';
    if (s >= 55) return 'Caution';
    if (s >= 40) return 'Risky';
    return 'Do not sign';
  }

  @override
  Widget build(BuildContext context) {
    final mood = _mood();

    IconData icon;
    Color color;
    String caption = (label ?? '').trim().isEmpty
        ? _defaultLabel(score)
        : label!.trim();

    switch (mood) {
      case RiskMood.good:
        icon = Icons.sentiment_very_satisfied_rounded;
        color = Colors.green;
        break;
      case RiskMood.meh:
        icon = Icons.sentiment_neutral_rounded;
        color = Colors.orange;
        break;
      case RiskMood.bad:
        icon = Icons.sentiment_very_dissatisfied_rounded;
        color = Colors.redAccent;
        break;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withOpacity(0.08),
            border: Border.all(color: color, width: 2),
          ),
          child: Icon(icon, size: size * 0.55, color: color),
        ),
        if (showCaption && caption.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            caption,
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w700, color: color),
          ),
          Text(
            'Risk score: ${score.clamp(0, 100).round()}',
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ],
    );
  }
}
