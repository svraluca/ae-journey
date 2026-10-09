'use strict';

const medicalTypes = new Set(['Hospital', 'MedicalClinic', 'MedicalBusiness',
  'Physician', 'Dentist', 'LocalBusiness', 'HealthAndBeautyBusiness']);
const fold = (s) => String(s || '').normalize('NFKD').toLowerCase()
    .replace(/[\u0300-\u036f]/g, '').replace(/ı/g, 'i').trim();
const profileUrl = (s) => String(s || '').split('#')[0].replace(/\/$/, '');

// The platform publisher and recommended providers must not supply geography.
function marketplaceProviderLocations(html, sourceUrl) {
  const locations = [];
  const visit = (item, mainEntity = false) => {
    if (Array.isArray(item)) return item.forEach((child) => visit(child));
    if (!item || typeof item !== 'object') return;
    const types = Array.isArray(item['@type']) ? item['@type'] : [item['@type']];
    const ref = profileUrl(item.url || item['@id']);
    if (types.some((type) => medicalTypes.has(type)) &&
        (ref === profileUrl(sourceUrl) || (mainEntity && !ref))) {
      const address = item.address;
      if (typeof address === 'string') locations.push(address);
      else if (address && typeof address === 'object') {
        locations.push(address.addressLocality ||
            [address.streetAddress, address.addressRegion, address.addressCountry].filter(Boolean).join(' '));
      }
    }
    for (const [key, value] of Object.entries(item)) visit(value, key === 'mainEntity');
  };
  for (const match of String(html || '').matchAll(/<script\b[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
    try { visit(JSON.parse(match[1])); } catch (_) { /* malformed metadata is not proof */ }
  }
  return [...new Set(locations.filter(Boolean))];
}

function providerLocationContext(html, sourceUrl) {
  return marketplaceProviderLocations(html, sourceUrl).map((s) => `Provider locality: ${s}`).join('\n');
}

function providerLocationConflicts(context, city) {
  const locations = String(context || '').split('\n')
      .filter((line) => line.startsWith('Provider locality: ')).map((line) => line.slice(19));
  const aliases = {istanbul: ['istanbul', 'constantinople'], bucharest: ['bucharest', 'bucuresti'],
    tirana: ['tirana', 'tirane'], rome: ['rome', 'roma'], milan: ['milan', 'milano']};
  const wanted = fold(city);
  const names = aliases[wanted] || [wanted];
  return locations.length > 0 && !locations.some((location) => names.some((name) =>
    new RegExp(`(?:^|[^\\p{L}])${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?:$|[^\\p{L}])`, 'u').test(fold(location))));
}

module.exports = {marketplaceProviderLocations, providerLocationContext, providerLocationConflicts};
