import 'package:uuid/uuid.dart';

class Procedure {
  Procedure({
    String? id,
    required this.title,
    required this.date,
    this.category,
    this.clinic,
    this.practitioner,
    this.product,
    this.volumeMl,
    this.beforePhotoPath,
    this.afterPhotoPath,
    this.zones = const [],
    this.cost,
    this.currency = 'EUR',
    this.recoveryDays,
    this.recoveryValue,
    this.recoveryUnit,
    this.painLevel,
    /// Matches form `GlowFeel.name`: painless | mild | moderate | intense
    this.feelLevel,
    this.recoveryDiary,
    this.followUpDate,
    this.redoAfterValue,
    this.redoAfterUnit,
    this.notes,
    this.aftercare,
    this.tags = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String title;
  final DateTime date;

  final String? category;
  final String? clinic;
  final String? practitioner;
  final String? product;
  final double? volumeMl;
  final String? beforePhotoPath;
  final String? afterPhotoPath;
  final List<String> zones;

  final num? cost;
  final String currency;

  final int? recoveryDays;
  final int? recoveryValue; // value in recoveryUnit
  final String? recoveryUnit; // 'days' | 'weeks' | 'months' | 'years'
  final String? painLevel; // 'none' | 'mild' | 'moderate' | 'intense'
  final String? feelLevel;
  final Map<String, String>? recoveryDiary; // e.g. {'D1':'😣','D2':'🙂'}
  final DateTime? followUpDate;
  final int? redoAfterValue;
  final String? redoAfterUnit; // 'days' | 'weeks' | 'months' | 'years'

  final String? notes;
  final String? aftercare;
  final List<String> tags;

  final DateTime createdAt;
  final DateTime updatedAt;

  Procedure copyWith({
    String? title,
    DateTime? date,
    String? category,
    String? clinic,
    String? practitioner,
    String? product,
    double? volumeMl,
    String? beforePhotoPath,
    String? afterPhotoPath,
    List<String>? zones,
    num? cost,
    String? currency,
    int? recoveryDays,
    int? recoveryValue,
    String? recoveryUnit,
    String? painLevel,
    String? feelLevel,
    Map<String, String>? recoveryDiary,
    DateTime? followUpDate,
    int? redoAfterValue,
    String? redoAfterUnit,
    String? notes,
    String? aftercare,
    List<String>? tags,
  }) {
    return Procedure(
      id: id,
      title: title ?? this.title,
      date: date ?? this.date,
      category: category ?? this.category,
      clinic: clinic ?? this.clinic,
      practitioner: practitioner ?? this.practitioner,
      product: product ?? this.product,
      volumeMl: volumeMl ?? this.volumeMl,
      beforePhotoPath: beforePhotoPath ?? this.beforePhotoPath,
      afterPhotoPath: afterPhotoPath ?? this.afterPhotoPath,
      zones: zones ?? this.zones,
      cost: cost ?? this.cost,
      currency: currency ?? this.currency,
      recoveryDays: recoveryDays ?? this.recoveryDays,
      recoveryValue: recoveryValue ?? this.recoveryValue,
      recoveryUnit: recoveryUnit ?? this.recoveryUnit,
      painLevel: painLevel ?? this.painLevel,
      feelLevel: feelLevel ?? this.feelLevel,
      recoveryDiary: recoveryDiary ?? this.recoveryDiary,
      followUpDate: followUpDate ?? this.followUpDate,
      redoAfterValue: redoAfterValue ?? this.redoAfterValue,
      redoAfterUnit: redoAfterUnit ?? this.redoAfterUnit,
      notes: notes ?? this.notes,
      aftercare: aftercare ?? this.aftercare,
      tags: tags ?? this.tags,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'title': title,
      'date': date.toIso8601String(),
      'category': category,
      'clinic': clinic,
      'practitioner': practitioner,
      'product': product,
      'volumeMl': volumeMl,
      'beforePhotoPath': beforePhotoPath,
      'afterPhotoPath': afterPhotoPath,
      'zones': zones,
      'cost': cost,
      'currency': currency,
      'recoveryDays': recoveryDays,
      'recoveryValue': recoveryValue,
      'recoveryUnit': recoveryUnit,
      'painLevel': painLevel,
      'feelLevel': feelLevel,
      'recoveryDiary': recoveryDiary,
      'followUpDate': followUpDate?.toIso8601String(),
      'redoAfterValue': redoAfterValue,
      'redoAfterUnit': redoAfterUnit,
      'notes': notes,
      'aftercare': aftercare,
      'tags': tags,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  static Procedure fromMap(Map<dynamic, dynamic> map) {
    final tagsRaw = map['tags'];
    final tags = tagsRaw is List ? tagsRaw.whereType<String>().toList() : <String>[];

    final zonesRaw = map['zones'];
    final zones = zonesRaw is List ? zonesRaw.whereType<String>().toList() : <String>[];

    final rdRaw = map['recoveryDiary'];
    final recoveryDiary = rdRaw is Map
        ? rdRaw.map((k, v) => MapEntry(k.toString(), v.toString()))
        : null;

    DateTime? tryParseDate(dynamic v) {
      if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
      return null;
    }

    final id = map['id'];
    final title = map['title'];
    final date = map['date'];

    if (id is! String || title is! String || date is! String) {
      throw const FormatException('Invalid procedure map');
    }

    final procedureDate = DateTime.parse(date);
    final fallbackStamp = DateTime(procedureDate.year, procedureDate.month, procedureDate.day);
    final parsedCreated = tryParseDate(map['createdAt']);
    final parsedUpdated = tryParseDate(map['updatedAt']);

    return Procedure(
      id: id,
      title: title,
      date: procedureDate,
      category: map['category'] as String?,
      clinic: map['clinic'] as String?,
      practitioner: map['practitioner'] as String?,
      product: map['product'] as String?,
      volumeMl: (map['volumeMl'] as num?)?.toDouble(),
      beforePhotoPath: map['beforePhotoPath'] as String?,
      afterPhotoPath: map['afterPhotoPath'] as String?,
      zones: zones,
      cost: map['cost'] as num?,
      currency: (map['currency'] as String?) ?? 'EUR',
      recoveryDays: map['recoveryDays'] as int?,
      recoveryValue: map['recoveryValue'] as int?,
      recoveryUnit: map['recoveryUnit'] as String?,
      painLevel: map['painLevel'] as String?,
      feelLevel: map['feelLevel'] as String?,
      recoveryDiary: recoveryDiary,
      followUpDate: tryParseDate(map['followUpDate']),
      redoAfterValue: map['redoAfterValue'] as int?,
      redoAfterUnit: map['redoAfterUnit'] as String?,
      notes: map['notes'] as String?,
      aftercare: map['aftercare'] as String?,
      tags: tags,
      // Stable fallbacks — avoid DateTime.now() so sort order survives reloads.
      createdAt: parsedCreated ?? parsedUpdated ?? fallbackStamp,
      updatedAt: parsedUpdated ?? parsedCreated ?? fallbackStamp,
    );
  }
}

/// Suggested next visit = procedure date + redo-after guidance (days / weeks / months / years).
/// Returns `null` when redo-after is unknown or invalid.
DateTime? computeSuggestedRedoAppointment({
  required DateTime procedureDate,
  int? redoAfterValue,
  String? redoAfterUnit,
}) {
  final v = redoAfterValue;
  final unit = (redoAfterUnit ?? '').trim();
  if (v == null || v < 1 || unit.isEmpty) return null;

  final base = DateTime(procedureDate.year, procedureDate.month, procedureDate.day);

  switch (unit) {
    case 'days':
      return base.add(Duration(days: v));
    case 'weeks':
      return base.add(Duration(days: v * 7));
    case 'months':
      final totalMonths = base.year * 12 + base.month - 1 + v;
      final y = totalMonths ~/ 12;
      final m = totalMonths % 12 + 1;
      final dim = DateTime(y, m + 1, 0).day;
      final day = base.day.clamp(1, dim);
      return DateTime(y, m, day);
    case 'years':
      return DateTime(base.year + v, base.month, base.day);
    default:
      return null;
  }
}

extension ProcedureRedoAppointmentX on Procedure {
  DateTime? get suggestedRedoAppointmentDate => computeSuggestedRedoAppointment(
        procedureDate: date,
        redoAfterValue: redoAfterValue,
        redoAfterUnit: redoAfterUnit,
      );
}

/// Newer treatment [Procedure.date] first.
///
/// Same calendar day: newer [Procedure.updatedAt] (last saved) first — so the entry you
/// just added or edited isn't stuck behind stale `createdAt` values.
///
/// Then [Procedure.createdAt], then `id` for a stable order.
int compareProceduresNewestFirst(Procedure a, Procedure b) {
  final byDate = b.date.compareTo(a.date);
  if (byDate != 0) return byDate;

  final byUpdated = b.updatedAt.compareTo(a.updatedAt);
  if (byUpdated != 0) return byUpdated;

  final byCreated = b.createdAt.compareTo(a.createdAt);
  if (byCreated != 0) return byCreated;

  return b.id.compareTo(a.id);
}

