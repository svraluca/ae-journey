/// Public feed card mirrored from a passport procedure with `community_live`.
class CommunityPost {
  const CommunityPost({
    required this.id,
    required this.ownerUid,
    required this.procedureId,
    required this.title,
    required this.date,
    required this.postedAt,
    this.category,
    this.clinic,
    this.practitioner,
    this.product,
    this.volumeMl,
    this.zones = const [],
    this.beforePhotoUrl,
    this.afterPhotoUrl,
    this.ownerDisplayName,
  });

  final String id;
  final String ownerUid;
  final String procedureId;
  final String title;
  final DateTime date;
  final DateTime postedAt;
  final String? category;
  final String? clinic;
  final String? practitioner;
  final String? product;
  final double? volumeMl;
  final List<String> zones;
  final String? beforePhotoUrl;
  final String? afterPhotoUrl;
  final String? ownerDisplayName;

  String get zoneLabel {
    if (zones.isNotEmpty) return zones.first;
    final cat = (category ?? '').trim();
    return cat.isEmpty ? 'Procedure' : cat;
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'ownerUid': ownerUid,
        'procedureId': procedureId,
        'title': title,
        'date': date.toIso8601String(),
        'postedAt': postedAt.toIso8601String(),
        'category': category,
        'clinic': clinic,
        'practitioner': practitioner,
        'product': product,
        'volumeMl': volumeMl,
        'zones': zones,
        'beforePhotoUrl': beforePhotoUrl,
        'afterPhotoUrl': afterPhotoUrl,
        'ownerDisplayName': ownerDisplayName,
      };

  static CommunityPost? fromMap(Map<String, dynamic> map, {String? docId}) {
    final id = (map['id'] as String?) ?? docId;
    final ownerUid = map['ownerUid'] as String?;
    final procedureId = map['procedureId'] as String?;
    final title = map['title'] as String?;
    if (id == null || ownerUid == null || procedureId == null || title == null) {
      return null;
    }

    DateTime? parseDate(dynamic v) {
      if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
      return null;
    }

    final date = parseDate(map['date']) ?? DateTime.now();
    final postedAt = parseDate(map['postedAt']) ?? date;
    final zonesRaw = map['zones'];
    final zones = zonesRaw is List ? zonesRaw.whereType<String>().toList() : <String>[];

    return CommunityPost(
      id: id,
      ownerUid: ownerUid,
      procedureId: procedureId,
      title: title,
      date: date,
      postedAt: postedAt,
      category: map['category'] as String?,
      clinic: map['clinic'] as String?,
      practitioner: map['practitioner'] as String?,
      product: map['product'] as String?,
      volumeMl: (map['volumeMl'] as num?)?.toDouble(),
      zones: zones,
      beforePhotoUrl: map['beforePhotoUrl'] as String?,
      afterPhotoUrl: map['afterPhotoUrl'] as String?,
      ownerDisplayName: map['ownerDisplayName'] as String?,
    );
  }
}
