import 'package:uuid/uuid.dart';

class Checkpoint {
  Checkpoint({
    String? id,
    required this.optionKey,
    required this.title,
    required this.date,
    this.photoPath,
    this.moodKey,
    this.note,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String optionKey; // e.g. 'd1', 'w1'
  final String title; // e.g. '1 Week checkpoint'
  final DateTime date;
  final String? photoPath;
  final String? moodKey; // 'bad' | 'okay' | 'good' | 'love'
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'optionKey': optionKey,
        'title': title,
        'date': date.toIso8601String(),
        'photoPath': photoPath,
        'moodKey': moodKey,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  static Checkpoint fromMap(Map<dynamic, dynamic> map) {
    final id = map['id'];
    final optionKey = map['optionKey'];
    final title = map['title'];
    final date = map['date'];
    if (id is! String || optionKey is! String || title is! String || date is! String) {
      throw const FormatException('Invalid checkpoint map');
    }

    DateTime? tryParseDate(dynamic v) {
      if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
      return null;
    }

    final d = DateTime.parse(date);
    final fallbackStamp = DateTime(d.year, d.month, d.day);
    final parsedCreated = tryParseDate(map['createdAt']);
    final parsedUpdated = tryParseDate(map['updatedAt']);

    return Checkpoint(
      id: id,
      optionKey: optionKey,
      title: title,
      date: d,
      photoPath: map['photoPath'] as String?,
      moodKey: map['moodKey'] as String?,
      note: map['note'] as String?,
      createdAt: parsedCreated ?? parsedUpdated ?? fallbackStamp,
      updatedAt: parsedUpdated ?? parsedCreated ?? fallbackStamp,
    );
  }
}

