import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lib/services/explore_compare_mix.dart';
import '../lib/services/explore_price_binding.dart';
import '../lib/services/explore_price_discovery_tool.dart';
import '../lib/services/explore_price_sanity.dart';
import '../lib/services/openai_service.dart';
import '../lib/ui/clinic_compare_price_display.dart';
import '../lib/ui/map_price_pin_bitmap.dart';
import 'explore_verified_card_titles_test.dart' as fixtures;

typedef Tariff = ({String name, int amount});
bool same(Tariff a, Tariff b) => a.name == b.name;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('returning to a tab preserves providers, order and their shown amounts', () {
    final shown = <Tariff>[(name:'Aster',amount:400),(name:'Cedar',amount:290)];
    final result = stabilizeExploreCompareRows<Tariff>(shown: shown,
      incoming: [(name:'Cedar',amount:340),(name:'Aster',amount:484),(name:'Elm',amount:500)],
      stillEligible: (_) => true, sameProvider: same);
    expect(result, [...shown,(name:'Elm',amount:500)]);
  });

  test('background discoveries do not replace four valid displayed providers', () {
    final shown = <Tariff>[for(var i=0;i<4;i++) (name:'Clinic $i',amount:200+i)];
    expect(stabilizeExploreCompareRows<Tariff>(shown: shown,
      incoming: [(name:'New Clinic',amount:87)], stillEligible: (_) => true,
      sameProvider: same),shown);
  });

  test('an invalid displayed source can be evicted and its empty slot filled', () {
    final result=stabilizeExploreCompareRows<Tariff>(shown:[(name:'Hair Salon',amount:115),(name:'Aster',amount:400)],
      incoming:[(name:'Cedar',amount:290)], stillEligible:(r)=>r.name!='Hair Salon',sameProvider:same);
    expect(result.map((r)=>r.name),['Aster','Cedar']);
  });

  test('saved anti-frizz Botox never qualifies as an injectable price', () {
    final hair=fixtures.clinic(canonical:'botox',procedure:'Botox',rawTitle:'Anti-frizz Botox',
      displayTitle:'Botox',amount:115,currency:'EUR',city:'Barcelona');
    expect(explorePriceIsVerified(hair),false);
  });

  test('the preceding hyaluronic acid row cannot supply a Botox amount', () {
    const text='Hyaluronic Acid - Expression Lines 484€ Botox - Expression Lines from 400€';
    expect(exploreBotoxAmountOwnedByFiller(evidence:text,priceMin:484,currency:'EUR'),true);
    expect(exploreBotoxAmountOwnedByFiller(evidence:text,priceMin:400,currency:'EUR'),false);
    expect(evaluateExtractedPriceCandidate(rawPriceText:'484 EUR',priceMin:484,currency:'EUR',
      extractionMethod:'html_table',rawEvidence:text,procedure:'Botox',logRejects:false).reason,
      'neighbouring_filler_amount');
  });

  test('explicit Botox one-unit tariff keeps its unit on both card and map', () {
    final row=fixtures.clinic(canonical:'botox',procedure:'Botox',rawTitle:'Botox (1 unit)',
      amount:40,currency:'AED',city:'Dubai').copyWith(priceType:'exact',
        priceEvidenceText:'BOTULINUM THERAPY | Botox (1 unit) – wrinkle correction 40 AED');
    expect(clinicCompareProcedurePriceDisplay(row,procedure:'Botox'),contains('/unit'));
    expect(mapPricePinShortLabel(row),contains('/unit'));
  });

  test('long surgical range remains a price on the map', () {
    final row=fixtures.clinic().copyWith(priceType:'range',priceMin:45000,priceMax:50000,
      rawPriceText:'45000–50000 AED',priceLabel:'45000–50000 AED',
      priceEvidenceText:'Rhinoplasty: 45000–50000 AED');
    expect(mapPricePinShortLabel(row),isNot('—'));
  });

  test('Starting Price is a from price even in a previously exact cache row', () {
    final row=fixtures.clinic(canonical:'breast_augmentation',procedure:'Breast augmentation',
      rawTitle:'Breast augmentation with implants',amount:27000,city:'Dubai')
      .copyWith(priceType:'exact',priceEvidenceText:'Breast augmentation with implants | Starting Price: AED 27000');
    expect(clinicCompareProcedurePriceDisplay(row,procedure:'Boob job'),startsWith('from '));
  });

  test('clinic Maps identity can match shared-brand medical and aesthetic sites', () {
    expect(exploreMapsProviderIdentityMatches(sourceName:'Turó Park Aesthetic',mapsName:'Turó Park Medical',
      sourceHost:'turoparkaesthetic.com',mapsHost:'turoparkmedical.com'),true);
    expect(exploreMapsProviderIdentityMatches(sourceName:'Aster Clinic',mapsName:'Cedar Medical',
      sourceHost:'asterclinic.com',mapsHost:'cedarmedical.com'),false);
    expect(exploreMapsProviderIdentityMatches(sourceName:'Benessia & Benestar',mapsName:'Benessia & Benestar',
      sourceHost:'fresha.com',mapsHost:'esbenessia.com',marketplace:true),true);
  });

  test('treatment title keeps dose and removes adjacent promotional copy', () {
    expect(exploreProcedureTitleWithoutPromotion('Lip Fillers 1 ml 30% OFF Save 300'),'Lip Fillers 1 ml');
    expect(exploreBreastProcedureDisplayName(rawProcedureText:'Silicone Breast Augmentation | 150 – 300 cc',
      evidence:'Silicone Breast Augmentation | 150 – 300 cc: 19999 AED – 25999 AED',
      priceMin:19999,currency:'AED'),contains('With implants · 150 – 300 cc'));
  });

  test('breast label omits unknown method but retains published implant detail', () {
    final generic = fixtures.clinic(canonical: 'breast_augmentation',
      procedure: 'Breast augmentation', rawTitle: 'Breast augmentation',
      amount: 6400, currency: 'EUR', city: 'Madrid');
    expect(exploreCardProcedureLabel(generic, selectedPill: 'Boob job'),
      'Breast augmentation');
    expect(exploreBreastProcedureDetail(rawProcedureText: 'Breast augmentation'),
      'Method not specified');
    final implants = generic.copyWith(rawProcedureText: 'Breast augmentation with implants',
      priceEvidenceText: 'Breast augmentation with implants | 6400 EUR');
    expect(exploreCardProcedureLabel(implants, selectedPill: 'Boob job'),
      'Breast augmentation · With implants');
  });

  test('display priority uses client accepted count and retries a rejected acknowledgement', () async {
    SharedPreferences.setMockInitialValues({});
    final reports=<Map>[];
    final client=MockClient((request) async {
      Object reply;
      if(request.url.path=='/health') {
        reply={'ok':true,'version':'0.11.95','progressive_jobs':true};
      } else if(request.url.path=='/discover-jobs') {
        expect((jsonDecode(request.body) as Map)['require_client_display_confirmation'],true);
        reply={'job_id':'active','status':'queued','enqueued':true};
      } else {
        expect(request.url.path,'/discover-jobs/active/display');
        reports.add(jsonDecode(request.body) as Map);
        reply={'accepted':reports.length>1};
      }
      return http.Response(jsonEncode(reply),200,headers:{'content-type':'application/json'});
    });
    addTearDown(client.close);
    final tool=ExplorePriceDiscoveryTool(client:client,baseUrl:'http://test');
    tool.focusDiscovery('botox-barcelona');
    await tool.enqueueDiscoveryJob(city:'Barcelona',procedure:'Botox',foreground:true,focusKey:'botox-barcelona');
    await tool.reportDisplayedCount(focusKey:'botox-barcelona',count:3);
    await tool.reportDisplayedCount(focusKey:'botox-barcelona',count:3);
    await tool.reportDisplayedCount(focusKey:'botox-barcelona',count:3);
    expect(reports.length,2);
    expect(reports.every((r)=>r['displayed_count']==3),true);
    expect(reports.last['display_seq'],greaterThan(reports.first['display_seq'] as int));
    tool.focusDiscovery('peels-barcelona');
    await tool.reportDisplayedCount(focusKey:'botox-barcelona',count:4);
    expect(reports.length,2);
  });
}
