"""Row-local exclusions for travel costs and geographical market tables."""
import re
import unicodedata


def fold(value):
    return ''.join(c for c in unicodedata.normalize('NFKD', str(value or '').lower())
                   if not unicodedata.combining(c)).replace('ı', 'i')


COMPARISON_CONTEXT = re.compile(
    r'\b(?:ulkeler\w*\s+gore|sehirler\w*\s+gore|'
    r'(?:prices?|costs?)\s+(?:by|across)\s+(?:countr\w*|cities)|'
    r'(?:precios?|costes?)\s+por\s+(?:paises|ciudades)|'
    r'prix\s+par\s+(?:pays|ville)|preise\s+nach\s+(?:land|stadt)|'
    r'prezzi\s+per\s+(?:paese|citta)|'
    r'average\s+\w*(?:\s+\w*){0,3}\s+price|typical\s+price\s+range|'
    r'worked\s+cost\s+example|global\s+market)\b', re.I)

TRAVEL_OWNER = re.compile(
    r'\b(?:international\s+flights?|flights?|airfare|travel\s+insurance|'
    r'extra\s+hotel\s+nights?|companion\s+accommodation|personal\s+meals|'
    r'vuelos?|seguro\s+de\s+viaje|ucak\s+bilet\w*|seyahat\s+sigorta\w*|'
    r'vols?|assurance\s+voyage|flug\w*|reiseversicherung|voli|assicurazione\s+viaggio)'
    r'\b[^|\n€$£₺]{0,60}$', re.I)
HAIR_ADJUNCT_OWNER = re.compile(
    r'\b(?:prp|platelet[- ]rich\s+plasma|mesotherap\w*|mezoterapi\w*|'
    r'minoxidil|finasteride)\b[^|\n€$£₺]{0,65}$', re.I)


def ancillary_price_reason(procedure, price_prefix):
    prefix = fold(price_prefix)
    if procedure == 'chemical_peel':
        # Apply to the priced row, not the whole clinic page. A mixed menu
        # may contain both genuine sessions and take-home products.
        purchase = re.search(r'\b(?:add\s+to\s+cart|buy\s+now|buy\s+online|shopping\s+cart|'
                             r'wholesale|supplier|distributor|at[- ]home|home[- ]use|take[- ]home|sepete\s+ekle|satin\s+al)\b', prefix)
        container = re.search(r'\b(?:bottles?|vials?|ampoules?|flacons?|kits?|sise\w*|siseler|'
                              r'solutions?|solusyon\w*|'
                              r'\d+(?:[.,]\d+)?\s*ml)\b', prefix)
        session = re.search(r'\b(?:per\s+session|single\s+session|treatment\s+session|'
                            r'professional\s+application|clinic\s+application|'
                            r'(?:face|facial|peel|peeling)\s+application|seans|sedinta)\b', prefix)
        if purchase or (container and not session):
            return 'peel_product_not_procedure'
    if TRAVEL_OWNER.search(prefix):
        return 'travel_cost_not_procedure'
    if procedure == 'hair_transplant' and HAIR_ADJUNCT_OWNER.search(prefix):
        return 'hair_adjunct_not_transplant'
    return None


def comparison_price_context(raw):
    text = fold(raw)
    # Geography-labelled amounts describe a market, even on a provider's site.
    # An address in Turkey and an exact table layout do not make them its fee.
    return bool(COMPARISON_CONTEXT.search(text) or re.search(
        r'\b(?:turkey|world|global|uk|us|eu|europe)\s+price\s*[:|]', text))


def medical_qa_price_context(url, raw):
    """FAQ portals discuss fees; they are not the provider of the treatment."""
    if re.search(r'(?:^|[./])hastalarsoruyor\.com(?:[/?#:]|$)', str(url).lower()):
        return True
    return bool(re.search(r'/(?:s-s-s|questions?|answers?)/', str(url).lower())
                and re.search(r'\b(?:devlet\s+hastaneler\w*|hastalar\s+soruyor|'
                              r'ask\s+(?:a\s+)?doctor|medical\s+questions?|'
                              r'patient\s+questions?|fiyatlarinin\s+bazi\s+ornekleri|'
                              r'fiyat\w*[^.!?\n]{0,100}ortalama|'
                              r'(?:average|typical|example)\s+(?:\w+\s+){0,3}(?:prices?|fees?))\b', fold(raw)))


def calendar_price_reason(amount, price_prefix, price_tail):
    """A question such as 'kaç TL 2026?' quotes a year, not a tariff."""
    if (1990 <= amount <= 2100 and amount == int(amount)
            and re.search(r'\b(?:kac|ne\s+kadar|how\s+much|cuanto(?:\s+cuesta)?|'
                          r'combien|wie\s+viel|quanto)\b[^|:\n]{0,45}$', fold(price_prefix))
            and re.match(r'^\s*\?', price_tail)):
        return 'calendar_year_not_price'
    return None
