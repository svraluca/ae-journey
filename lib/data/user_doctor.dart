import 'procedure.dart';

/// A doctor (or clinic-only contact) derived from the user's saved procedures.
class UserDoctor {
  const UserDoctor({
    required this.key,
    required this.name,
    required this.clinic,
    required this.procedures,
  });

  final String key;
  final String name;
  final String? clinic;
  final List<Procedure> procedures;

  int get treatmentCount => procedures.length;

  String get treatmentCountLabel {
    final n = treatmentCount;
    return n == 1 ? '1 treatment' : '$n treatments';
  }

  String get initials {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'D';
    if (parts.length == 1) {
      final s = parts.first;
      return s.substring(0, s.length >= 2 ? 2 : 1).toUpperCase();
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  String? get clinicLine {
    final c = (clinic ?? '').trim();
    return c.isEmpty ? null : c;
  }
}

String _norm(String s) => s.trim().toLowerCase();

/// Groups completed procedures by doctor name + clinic.
///
/// Procedures with neither practitioner nor clinic are skipped.
List<UserDoctor> userDoctorsFromProcedures(Iterable<Procedure> procedures) {
  final buckets = <String, _Agg>{};

  for (final p in procedures) {
    final name = (p.practitioner ?? '').trim();
    final clinic = (p.clinic ?? '').trim();
    if (name.isEmpty && clinic.isEmpty) continue;

    final displayName = name.isNotEmpty ? name : clinic;
    final displayClinic = name.isNotEmpty ? (clinic.isEmpty ? null : clinic) : null;
    final key = '${_norm(name)}|${_norm(clinic)}';

    final agg = buckets.putIfAbsent(
      key,
      () => _Agg(name: displayName, clinic: displayClinic),
    );
    agg.procedures.add(p);
  }

  final doctors = buckets.entries
      .map(
        (e) {
          final items = e.value.procedures..sort(compareProceduresNewestFirst);
          return UserDoctor(
            key: e.key,
            name: e.value.name,
            clinic: e.value.clinic,
            procedures: List<Procedure>.unmodifiable(items),
          );
        },
      )
      .toList()
    ..sort((a, b) {
      // Most recently treated doctors first ("last doctors").
      final aDate = a.procedures.isEmpty ? DateTime.fromMillisecondsSinceEpoch(0) : a.procedures.first.date;
      final bDate = b.procedures.isEmpty ? DateTime.fromMillisecondsSinceEpoch(0) : b.procedures.first.date;
      final byDate = bDate.compareTo(aDate);
      if (byDate != 0) return byDate;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  return doctors;
}

class _Agg {
  _Agg({required this.name, required this.clinic});

  final String name;
  final String? clinic;
  final List<Procedure> procedures = [];
}
