'use strict';

const fold = (value) => String(value || '').toLowerCase().normalize('NFKD')
    .replace(/\p{M}/gu, '').replace(/ı/g, 'i');

/** Row-local technique evidence; provider context never implies a blacklist. */
function injectableScopeRejection({procedure, label = '', evidence = '', provider = '', sourceUrl = ''}) {
  const requested = fold(procedure);
  const botox = /botox|botulin|toxin|neuromodul|ботокс|بوتوكس/.test(requested);
  const filler = requested === 'filler' || /filler|hyaluron|hialuron|relleno|aumento.*labios|фил[ъе]р|فيلر/.test(requested);
  if (!botox && !filler) return null;
  const local = fold(`${label} ${evidence}`);
  const adjunct = local.replace(/\b(?:numbing|anaesthetic|anesthetic)\s+cream\b|\bcrema\s+anestesica\b/g, '');
  if (/\b(?:creams?|cremas?|cremes?|serums?|serum|lotion\w*|moisturi\w*|cosmetic\s+products?|skincare|skin\s+care|topical\w*|topic[oa]\w*)\b|крем\w*|сыворот\w*|كريم|مصل/.test(adjunct)) {
    return 'topical_product_not_injectable';
  }
  if (filler && /hyaluron\w*\s*[- ]*pen\b|hialuron\w*\s*[- ]*pen\b|needle[- ]?(?:less|free)|sin\s+agujas?|sem\s+agulhas?|sans\s+aiguilles?|senza\s+aghi|ohne\s+nadeln?|fara\s+ace|ignesiz|pa\s+gjilper\w*|без\s+игл\w*|без\s+игли|بدون\s+(?:ابر|إبر)/.test(local)) {
    return 'needleless_not_injectable_filler';
  }
  if (botox && /(?:hair|haar|capillary|cabelo|cabelos|capelli|cheveux|par|flok\w*|sac)\s*[- ]*botox|botox\s*(?:for\s+)?(?:hair|haar|capilar|capillaire|capelli|cheveux|cabelo|par|flok\w*|sac)|ботокс\s+(?:для\s+)?волос|ботокс\s+за\s+коса|بوتوكس\s+(?:لل)?شعر|anti[- ]?frizz|anti[- ]?encresp|keratin\w*|straightening|alisado|\b(?:media\s+melena|pelo\s+(?:corto|largo)|short\s+hair|long\s+hair)\b/.test(local)) {
    return 'noninjectable_botox';
  }
  const identity = fold(`${provider} ${sourceUrl}`).replace(/[-_]/g, ' ');
  const beauty = /\b(?:hair|nails?|nailbar|manicur\w*|pedicur\w*|barber\w*|peluquer\w*|perruquer\w*|coiffeur\w*|parrucchier\w*|cabeleireir\w*|kapper\w*|friseur\w*|kuafor\w*|floktore|unghii|ongler\w*)\b|(?:hair|nail)[-_](?:salon|studio)|парикмахер\w*|маникюр\w*/.test(identity);
  const clinical = /\b(?:inject\w*|injections?|infiltr\w*|iniezion\w*|inyecci\w*|jeringas?|syringes?|dysport|xeomin|azzalure|bocouture|neuromodul\w*|neurotox\w*|botulin\w*|juvederm|restylane|teosyal|belotero|revolax)\b|dermal\s+fillers?|lip\s+fillers?|toxina\s+botulin\w*|\b(?:1|2|3|one|two|three)\s*(?:areas?|zones?|zonas?)\b|\b(?:per|por)\s+(?:unit|unidad)\w*\b|инъекц\w*|инжекц\w*|حقن/.test(local);
  if (beauty && !clinical) return botox ? 'noninjectable_botox' : 'injectable_technique_unverified';
  return null;
}

module.exports = {injectableScopeRejection};
