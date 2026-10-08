import 'package:flutter/foundation.dart';

import 'openai_service.dart';

/// Bumped when the user saves procedure interests so Explore can refresh tabs.
final exploreInterestRevision = ValueNotifier<int>(0);

/// One selectable Explore interest and the Compare tab it becomes.
class ExploreProcedureInterest {
  const ExploreProcedureInterest({
    required this.id,
    required this.label,
    required this.pill,
  });

  final String id;
  final String label;

  /// Canonical Compare pill key from [kExploreComparePills].
  final String pill;
}

/// Procedures that can become Compare tabs.
const kExploreSelectableInterests = <ExploreProcedureInterest>[
  ExploreProcedureInterest(id: 'botox', label: 'Botox', pill: 'Botox'),
  ExploreProcedureInterest(id: 'fillers', label: 'Fillers', pill: 'Fillers'),
  ExploreProcedureInterest(id: 'peels', label: 'Peels', pill: 'Peels'),
  ExploreProcedureInterest(
    id: 'rhinoplasty',
    label: 'Rhinoplasty',
    pill: 'Rhinoplasty',
  ),
  ExploreProcedureInterest(
    id: 'breast',
    label: 'Breast augmentation',
    pill: 'Boob job',
  ),
  ExploreProcedureInterest(
    id: 'hair',
    label: 'Hair transplant',
    pill: 'Hair',
  ),
];

/// Locked teasers — visible on personalization, not Compare tabs yet.
/// Shown in order; the UI may collapse some behind a “More” chip.
const kExploreLockedInterestLabels = <String>[
  'Blepharoplasty',
  'Facelift',
  'Liposuction',
  'Vaginal rejuvenation',
  'Brazilian butt lift',
  'Sculptra',
  'Morpheus',
  'HIFU',
  'Penile enlargement',
  'Scar removal',
  'Ear plasty',
  'Tummy tuck',
  'Neck lift',
  'Brow lift',
  'Chin implant',
  'Thread lift',
  'CoolSculpting',
  'Laser resurfacing',
  'Microneedling',
  'PRP facial',
  'Breast lift',
  'Gynecomastia',
  'Calf implants',
];

/// How many locked chips to show before the “More” control.
const kExploreLockedInterestsPreviewCount = 10;

/// Short labels used in the Compare pill strip.
String exploreInterestTabLabel(String pill) {
  switch (exploreCanonicalComparePill(pill)) {
    case 'Boob job':
      return 'Breast';
    case 'Hair':
      return 'Hair';
    default:
      return exploreCanonicalComparePill(pill);
  }
}

List<String> exploreInterestPillsFromIds(Iterable<String> ids) {
  final wanted = {for (final id in ids) id.trim().toLowerCase()};
  final out = <String>[];
  for (final interest in kExploreSelectableInterests) {
    if (!wanted.contains(interest.id)) continue;
    if (out.contains(interest.pill)) continue;
    out.add(interest.pill);
  }
  return out;
}

/// Prefer the user's selection; fall back to the full strip when empty/unset.
List<String> exploreComparePillsForSelection(List<String>? selectedPills) {
  if (selectedPills == null || selectedPills.isEmpty) {
    return List<String>.from(kExploreComparePills);
  }
  final ordered = <String>[];
  for (final pill in kExploreComparePills) {
    if (selectedPills.any((s) => exploreCanonicalComparePill(s) == pill)) {
      ordered.add(pill);
    }
  }
  return ordered.isEmpty ? List<String>.from(kExploreComparePills) : ordered;
}
