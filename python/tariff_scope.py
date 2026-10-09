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
    if TRAVEL_OWNER.search(prefix):
        return 'travel_cost_not_procedure'
    if procedure == 'hair_transplant' and HAIR_ADJUNCT_OWNER.search(prefix):
        return 'hair_adjunct_not_transplant'
    return None


def comparison_price_context(raw):
    return bool(COMPARISON_CONTEXT.search(fold(raw)))


def calendar_price_reason(amount, price_prefix, price_tail):
    """A question such as 'kaç TL 2026?' quotes a year, not a tariff."""
    if (1990 <= amount <= 2100 and amount == int(amount)
            and re.search(r'\b(?:kac|ne\s+kadar|how\s+much|cuanto(?:\s+cuesta)?|'
                          r'combien|wie\s+viel|quanto)\b[^|:\n]{0,45}$', fold(price_prefix))
            and re.match(r'^\s*\?', price_tail)):
        return 'calendar_year_not_price'
    return None
