"""Row-local injectable checks shared by discovery and saved-price serving.

Provider names supply context, never a clinic blacklist. A beauty venue may
offer medical treatments, but an ambiguous menu title cannot establish that.
"""
import re
import unicodedata


def _fold(value):
    return "".join(c for c in unicodedata.normalize("NFKD", str(value or "").lower())
                   if not unicodedata.combining(c)).replace("ı", "i")


HAIR_BOTOX = (
    r"(?:hair|haar|capillary|cabelo|cabelos|capelli|cheveux|par|flok\w*|sac)\s*[- ]*botox|"
    r"botox\s*(?:for\s+)?(?:hair|haar|capilar|capillaire|capelli|cheveux|cabelo|par|flok\w*|sac)|"
    r"ботокс\s+(?:для\s+)?волос|ботокс\s+за\s+коса|بوتوكس\s+(?:لل)?شعر|"
    r"anti[- ]?frizz|anti[- ]?encresp|keratin\w*|straightening|alisado|"
    r"\b(?:media\s+melena|pelo\s+(?:corto|largo)|short\s+hair|long\s+hair)\b"
)
NEEDLELESS = (
    r"hyaluron\w*\s*[- ]*pen\b|hialuron\w*\s*[- ]*pen\b|"
    r"needle[- ]?(?:less|free)|sin\s+agujas?|sem\s+agulhas?|sans\s+aiguilles?|"
    r"senza\s+aghi|ohne\s+nadeln?|fara\s+ace|ignesiz|pa\s+gjilper\w*|"
    r"без\s+игл\w*|без\s+игли|بدون\s+(?:ابر|إبر)"
)
TOPICAL = (
    r"\b(?:creams?|cremas?|cremes?|serums?|serum|lotion\w*|moisturi\w*|"
    r"cosmetic\s+products?|skincare|skin\s+care|topical\w*|topic[oa]\w*)\b|"
    r"крем\w*|сыворот\w*|كريم|مصل"
)
BEAUTY_PROVIDER = (
    r"\b(?:hair|nails?|nailbar|manicur\w*|pedicur\w*|barber\w*|peluquer\w*|"
    r"perruquer\w*|coiffeur\w*|parrucchier\w*|cabeleireir\w*|kapper\w*|"
    r"friseur\w*|kuafor\w*|floktore|unghii|ongler\w*)\b|"
    r"(?:hair|nail)[-_](?:salon|studio)|парикмахер\w*|маникюр\w*"
)
CLINICAL = (
    r"\b(?:inject\w*|injections?|infiltr\w*|iniezion\w*|inyecci\w*|"
    r"jeringas?|syringes?|dysport|xeomin|azzalure|bocouture|"
    r"neuromodul\w*|neurotox\w*|botulin\w*|juvederm|restylane|teosyal|"
    r"belotero|revolax)\b|dermal\s+fillers?|lip\s+fillers?|"
    r"toxina\s+botulin\w*|\b(?:1|2|3|one|two|three)\s*(?:areas?|zones?|zonas?)\b|"
    r"\b(?:per|por)\s+(?:unit|unidad)\w*\b|инъекц\w*|инжекц\w*|حقن"
)
_PATTERNS = {key: re.compile(value, re.I) for key, value in {
    "hair": HAIR_BOTOX, "needleless": NEEDLELESS, "topical": TOPICAL,
    "beauty": BEAUTY_PROVIDER, "clinical": CLINICAL,
}.items()}


def injectable_scope_rejection(procedure, label="", evidence="", provider="", source_url=""):
    """Return a reason or None. Only treatment-local text establishes technique."""
    requested = _fold(procedure)
    botox = bool(re.search(r"botox|botulin|toxin|neuromodul|ботокс|بوتوكس", requested))
    filler = requested == "filler" or bool(re.search(
        r"filler|hyaluron|hialuron|relleno|aumento.*labios|фил[ъе]р|فيلر", requested))
    if not (botox or filler):
        return None
    local = _fold(f"{label} {evidence}")
    # An anaesthetic used with an injection does not turn it into skincare.
    adjunct = re.sub(r"\b(?:numbing|anaesthetic|anesthetic)\s+cream\b|"
                     r"\bcrema\s+anestesica\b", "", local)
    if _PATTERNS["topical"].search(adjunct):
        return "topical_product_not_injectable"
    if filler and _PATTERNS["needleless"].search(local):
        return "needleless_not_injectable_filler"
    if botox and _PATTERNS["hair"].search(local):
        return "noninjectable_botox"
    identity = _fold(f"{provider} {source_url}").replace("-", " ").replace("_", " ")
    if _PATTERNS["beauty"].search(identity) and not _PATTERNS["clinical"].search(local):
        return "noninjectable_botox" if botox else "injectable_technique_unverified"
    return None
