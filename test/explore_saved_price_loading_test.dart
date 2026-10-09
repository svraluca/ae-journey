import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/services/explore_google_price_store.dart';
import '../lib/services/explore_price_sanity.dart';
import '../lib/services/explore_saved_price_loader.dart';
import '../lib/ui/clinic_compare_price_display.dart';

class _Snapshot implements DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.id, this.value);
  @override
  final String id;
  final Map<String, dynamic>? value;
  @override
  bool get exists => value != null;
  @override
  Map<String, dynamic>? data() => value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Document implements DocumentReference<Map<String, dynamic>> {
  _Document(this.db, this.id);
  final _Firestore db;
  @override
  final String id;
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    final source = options?.source ?? Source.serverAndCache;
    db.reads.add((id, source));
    if (source != Source.cache && db.serverGate != null) await db.serverGate!.future;
    return _Snapshot(id, db.documents[id]);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Collection implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.db);
  final _Firestore db;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) => _Document(db, path!);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Firestore implements FirebaseFirestore {
  final documents = <String, Map<String, dynamic>>{};
  final reads = <(String, Source)>[];
  Completer<void>? serverGate;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, ExploreGooglePriceStore.collection);
    return _Collection(this);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _document({bool invalid = false}) => {
  'cachedAt': Timestamp.fromDate(DateTime.now().subtract(const Duration(days: 40))),
  'clinics': [{
    'name': 'Aster Medical Clinic', 'has_procedure': true,
    'price_min': 330, 'price_max': 330, 'currency': 'EUR',
    'raw_price_text': '330 EUR', 'raw_procedure_text': 'Lip filler 1 ml',
    'brand': 'Dermal filler', 'procedure_canonical': 'filler',
    'price_source_url': 'https://aster.example/lip-filler/',
    'price_evidence_text': invalid ? 'Financiación hasta 330 EUR' : 'Lip filler 1 ml | 330 EUR',
    'extraction_method': 'html_table', 'price_verified': true,
    'price_verification_status': 'official_website',
    'price_extract_revision': kExplorePriceExtractRevision,
  }],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saved procedure aliases preserve a specific filler request', () {
    expect(exploreSavedProcedureKeys('Botox anti-wrinkle injection'),
        ['Botox anti-wrinkle injection', 'botox']);
    expect(exploreSavedProcedureKeys('dermal filler lips cheeks'),
        ['dermal filler lips cheeks', 'dermal filler']);
    expect(exploreSavedProcedureKeys('chin filler'), ['chin filler']);
  });

  test('native alias cache paints despite an empty current doc and blocked server', () async {
    final db = _Firestore()..serverGate = Completer<void>();
    const procedure = 'dermal filler lips cheeks';
    db.documents[ExploreGooglePriceStore.docId(city: 'Madrid', cityId: 'place_test',
        procedure: procedure)] = {'clinics': []};
    db.documents[ExploreGooglePriceStore.docId(city: 'Madrid', cityId: 'place_test',
        procedure: 'dermal filler', revisionOverride: 'v13')] = _document();
    final store = ExploreGooglePriceStore.forTesting(firestore: db, isSignedIn: () => true);
    final rows = await store.load(city: 'Madrid', cityId: 'place_test', procedure: procedure);
    expect(rows.single['price_min'], 330);
    expect(rows.single['price_is_stale'], true);
    expect(db.reads.every((read) => read.$2 == Source.cache), true);
    final count = db.reads.length;
    await store.load(city: 'Madrid', cityId: 'place_test', procedure: procedure);
    expect(db.reads.length, count);
  });

  test('an invalid newer doc cannot mask an independently valid older alias', () async {
    final db = _Firestore();
    db.documents[ExploreGooglePriceStore.docId(city: 'Madrid', cityId: 'place_test',
        procedure: 'dermal filler lips cheeks')] = _document(invalid: true);
    db.documents[ExploreGooglePriceStore.docId(city: 'Madrid',
        procedure: 'dermal filler', revisionOverride: 'v12')] = _document();
    final store = ExploreGooglePriceStore.forTesting(firestore: db, isSignedIn: () => true);
    final rows = await store.load(city: 'Madrid', cityId: 'place_test',
        procedure: 'dermal filler lips cheeks');
    expect(rows.single['price_min'], 330);
  });

  test('an empty read is not cached for the remainder of the session', () async {
    final db = _Firestore();
    final store = ExploreGooglePriceStore.forTesting(firestore: db, isSignedIn: () => true);
    expect(await store.load(city: 'Madrid', cityId: 'place_test',
        procedure: 'dermal filler'), isEmpty);
    db.documents[ExploreGooglePriceStore.docId(city: 'Madrid', cityId: 'place_test',
        procedure: 'dermal filler')] = _document();
    expect(await store.load(city: 'Madrid', cityId: 'place_test',
        procedure: 'dermal filler'), hasLength(1));
  });

  test('signed-out cache reads are diagnosed without hitting Firestore', () async {
    final db = _Firestore();
    final store = ExploreGooglePriceStore.forTesting(firestore: db, isSignedIn: () => false);
    expect(await store.load(city: 'Madrid', cityId: 'place_test', procedure: 'botox'), isEmpty);
    expect(db.reads, isEmpty);
  });

  test('a ready source paints before an unrelated slow store completes', () async {
    final slow = Completer<List<int>>();
    final painted = <List<int>>[];
    var finished = false;
    final pending = loadExploreSavedPrices<int>(
      sources: {'ready': Future.value([1]), 'slow': slow.future},
      select: (rows) => rows.where((row) => row > 0).toSet().toList(),
      onProgress: (rows) => painted.add(List.of(rows)),
    ).then((rows) { finished = true; return rows; });
    await Future<void>.delayed(Duration.zero);
    expect(painted, [[1]]);
    expect(finished, false);
    slow.complete([2]);
    expect(await pending, [1, 2]);
  });

  test('a late cache result still paints after the initial wait deadline', () async {
    final late = Completer<List<int>>();
    final painted = Completer<List<int>>();
    final first = await loadExploreSavedPrices<int>(
      sources: {'late': late.future}, select: List.of,
      deadline: Duration.zero, onProgress: painted.complete,
    );
    expect(first, isEmpty);
    late.complete([3]);
    expect(await painted.future, [3]);
  });

  test('queued, running and index-loading empty screens show search', () {
    for (final hasComparison in [false, true]) {
      expect(exploreShouldShowInitialSearch(hasComparison: hasComparison,
          verifiedCount: 0, loadingMore: true), true);
    }
    expect(exploreShouldShowInitialSearch(hasComparison: true,
        verifiedCount: 0, loadingMore: false), false);
    expect(exploreShouldShowInitialSearch(hasComparison: true,
        verifiedCount: 1, loadingMore: true), false);
  });
}
