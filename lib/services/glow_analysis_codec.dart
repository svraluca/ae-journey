import 'glow_up_pipeline.dart';

/// JSON snapshot of [GlowAnalysisResult] for job persistence and history.
class GlowAnalysisCodec {
  GlowAnalysisCodec._();

  static Map<String, dynamic> encode(GlowAnalysisResult r) {
    return {
      'originalPath': r.originalPath,
      'rawPhotoPath': r.rawPhotoPath,
      'enhancedUrl': r.enhancedUrl,
      'sliderBeforePath': r.sliderBeforePath,
      'sliderAfterPath': r.sliderAfterPath,
      'sliderSideBySidePath': r.sliderSideBySidePath,
      'error': r.error,
      'scores': {
        'glowScore': r.scores.glowScore,
        'potentialScore': r.scores.potentialScore,
        'zones': [
          for (final z in r.scores.zones)
            {
              'name': z.name,
              'score': z.score,
              'needsWork': z.needsWork,
              'asymmetry': z.asymmetry,
            },
        ],
        'skinMetrics': [
          for (final m in r.scores.skinMetrics)
            {'name': m.name, 'value': m.value},
        ],
      },
      'dissolveZones': [
        for (final d in r.dissolveZones)
          {
            'zone': d.zone,
            'confidence': d.confidence.name,
            'note': d.note,
          },
      ],
      if (r.faceReport != null) 'faceReport': _encodeFaceReport(r.faceReport!),
    };
  }

  static GlowAnalysisResult decode(Map<String, dynamic> map) {
    final scoresMap = map['scores'] as Map<String, dynamic>? ?? {};
    final zones = [
      for (final z in (scoresMap['zones'] as List? ?? []))
        if (z is Map<String, dynamic>)
          ZoneScore(
            z['name'] as String? ?? '',
            (z['score'] as num?)?.toDouble() ?? 0,
            needsWork: z['needsWork'] == true,
            asymmetry: (z['asymmetry'] as num?)?.toDouble() ?? 0,
          ),
    ];
    final metrics = [
      for (final m in (scoresMap['skinMetrics'] as List? ?? []))
        if (m is Map<String, dynamic>)
          SkinMetric(
            m['name'] as String? ?? '',
            (m['value'] as num?)?.toDouble() ?? 0,
          ),
    ];
    final scores = GlowScores(
      glowScore: (scoresMap['glowScore'] as num?)?.round() ?? 0,
      potentialScore: (scoresMap['potentialScore'] as num?)?.round() ?? 0,
      zones: zones,
      skinMetrics: metrics,
    );

    FaceAnalysisReport? report;
    final fr = map['faceReport'];
    if (fr is Map<String, dynamic>) {
      report = FaceAnalysisReport.fromJson(fr);
    }

    final dissolve = [
      for (final d in (map['dissolveZones'] as List? ?? []))
        if (d is Map<String, dynamic>)
          DissolveZone(
            zone: d['zone'] as String? ?? '',
            confidence: DissolveConfidence.values.firstWhere(
              (c) => c.name == (d['confidence'] as String?),
              orElse: () => DissolveConfidence.medium,
            ),
            note: d['note'] as String? ?? '',
          ),
    ];

    return GlowAnalysisResult(
      originalPath: map['originalPath'] as String? ?? '',
      rawPhotoPath: map['rawPhotoPath'] as String?,
      enhancedUrl: map['enhancedUrl'] as String?,
      sliderBeforePath: map['sliderBeforePath'] as String?,
      sliderAfterPath: map['sliderAfterPath'] as String?,
      sliderSideBySidePath: map['sliderSideBySidePath'] as String?,
      scores: scores,
      faceReport: report,
      dissolveZones: dissolve,
      error: map['error'] as String?,
    );
  }

  static Map<String, dynamic> _encodeFaceReport(FaceAnalysisReport r) {
    return {
      'overview': r.overview,
      'overall_score': r.overallScore,
      'findings': [
        for (final f in r.findings)
          {
            'area': f.area,
            'status': f.status,
            'note': f.note,
            'severity': f.severity,
            'recommend_edit': f.recommendEdit,
          },
      ],
      'glow_up_preview': {
        'explanation': r.glowUpExplanation,
        'procedures': [
          for (final p in r.proceduresSimulated)
            {'name': p.name, 'zone': p.zone, 'change': p.change},
        ],
        'image_edit_prompt': r.imageEditPrompt,
      },
      'asymmetry_assessment': {
        'severity': r.asymmetry.severity,
        'observed': r.asymmetry.observed,
        'corrected_in_preview': r.asymmetry.correctedInPreview,
      },
      'filler_assessment': {
        'summary': r.filler.summary,
        'zones': [
          for (final z in r.filler.zones)
            {'area': z.area, 'verdict': z.verdict, 'note': z.note},
        ],
      },
    };
  }
}
