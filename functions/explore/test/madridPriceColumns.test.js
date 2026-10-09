'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {extractPriceEvidence} = require('../priceExtractor');
const {selectEvidenceForProcedure} = require('../procedureMatch');
const {classifyExplorePricePageContext,
  exploreEvidenceIsClinicOwnedPrice} = require('../priceOwnership');

// Reduced regression fixtures based on published DOM structures. These are
// deliberately not full website snapshots; hashes/excerpts of the fetched
// pages are recorded in verification/user_followup_source_audit.json.
const sourceUrl = 'https://clinic.example/precios/';

test('ANTES never supplies an active filler fee or contaminates its range', () => {
  const rows = extractPriceEvidence({sourceUrl, html: `
    <h1>Ácido hialurónico — precios</h1><table><tbody>
    <tr><td>PRECIOS</td><td>ANTES</td><td>1VIAL (AHORA)</td><td>2VIALES (AHORA)</td></tr>
    <tr><td>Aumento de labios</td><td>400 €</td><td>330 €</td><td>600 €</td></tr>
    </tbody></table>`});
  const selected = selectEvidenceForProcedure(rows, 'lip filler');
  assert.ok(selected);
  assert.equal(selected.priceMin, 330);
  assert.ok(!selected.priceMax || selected.priceMax === 330);
  assert.match(selected.rawProcedureText, /1\s*vial/i);
  assert.doesNotMatch(selected.rawEvidence, /400|600/);
  assert.equal(rows.some((row) => row.priceMin === 400), false);
});

test('current column is selected even when it costs more than the old column', () => {
  const rows = extractPriceEvidence({sourceUrl, html: `
    <table><tr><th>Tratamiento</th><th>Previous price</th><th>Current price</th></tr>
    <tr><td>Lip filler 1 ml</td><td>300 €</td><td>350 €</td></tr></table>`});
  const selected = selectEvidenceForProcedure(rows, 'lip filler');
  assert.ok(selected);
  assert.equal(selected.priceMin, 350);
  assert.equal(rows.some((row) => row.priceMin === 300), false);
});

test('conditional friends-pack DOM cannot leak into a standalone filler tariff', () => {
  const rows = extractPriceEvidence({sourceUrl, html: `
    <article class="promo-card"><h3>Pack Amigas</h3>
    <p>(Aumento de labios o tratamiento antiarrugas)</p>
    <p>Ven con una amiga y disfruten de un precio especial.</p>
    <div class="promo-price-wrapper"><span class="current-price">250€</span>
    <del aria-label="Precio anterior">350€</del></div>
    <span>*Precio para cada persona</span></article>
    <p>Aumento de labios 1 ml 380 €</p>`});
  const selected = selectEvidenceForProcedure(rows, 'lip filler');
  assert.ok(selected);
  assert.equal(selected.priceMin, 380);
  assert.equal(rows.some((row) => row.priceMin === 250), false);
});

test('explicit national-average nonownership overrides a price menu and own wording', () => {
  const pageText = 'Los precios son indicativos de la media en España en el 2026. ' +
      'No representan los precios aplicados en la consulta del Dr. Ejemplo.';
  const ctx = classifyExplorePricePageContext({sourceUrl, pageText});
  assert.equal(ctx, 'explicit_non_owned_prices');
  assert.equal(exploreEvidenceIsClinicOwnedPrice({pageContext: ctx,
    rawProcedureText: 'Rhinoplasty', rawEvidence: 'Our rhinoplasty starts from €7500'}), false);
  assert.deepEqual(extractPriceEvidence({sourceUrl, html: `
    <p>${pageText}</p><table><tr><td>Rinoplastia ultrasónica</td><td>7.500–9.000 €</td></tr>
    <tr><td>Aumento mamario con implantes</td><td>6.000–8.000 €</td></tr></table>`}), []);
  assert.notEqual(classifyExplorePricePageContext({sourceUrl,
    pageText: 'Nuestros precios aplicados en la consulta: Rinoplastia 7500 €.'}), ctx);
});

test('a platform that disclaims being a medical office cannot become the treating clinic', () => {
  const html = '<p>Esta plataforma no es un consultorio médico.</p>' +
      '<p>Dr. Carlos Ejemplo — Aumento de pecho con implantes 3490 €</p>';
  assert.deepEqual(extractPriceEvidence({sourceUrl, html}), []);
  assert.equal(exploreEvidenceIsClinicOwnedPrice({
    pageContext: 'non_clinic_booking_platform',
    rawEvidence: 'Our breast augmentation starts from 3490 €'}), false);
});
