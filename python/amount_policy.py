"""Generic card amount bounds, matching Flutter's explore_price_sanity.dart.

These are rejection bands, not exchange rates or replacement prices. Never
convert or clamp the published amount. Explicit unit rates retain their scope.
"""
import math
import re


def plausible_amount_band(currency, procedure):
    currency = (currency or '').strip().upper()
    low, high = {
        'botox': (8, 800), 'filler': (30, 5000),
        'chemical_peel': (10, 5000), 'rhinoplasty': (1500, 100000),
        'breast_augmentation': (500, 100000),
        'hair_transplant': (300, 100000),
    }.get(procedure, (10, 100000))
    if procedure == 'botox' and currency == 'BGN':
        low, high = 80, 4000
    scales = {
        'RON': (5, 5), 'LEI': (5, 5), 'MDL': (5, 5),
        'ALL': (80, 120), 'LEK': (80, 120), 'TRY': (10, 35), 'TL': (10, 35),
        'KRW': (400, 2000), 'JPY': (50, 200), 'IDR': (5000, 20000),
        'INR': (30, 100), 'THB': (12, 40), 'HUF': (120, 400), 'CZK': (8, 30),
        'COP': (200, 2000), 'CLP': (200, 2000), 'ARS': (200, 2000),
    }
    if currency in scales:
        minimum, maximum = scales[currency]
        return low * minimum, high * maximum
    if currency in {'AED', 'SAR', 'QAR'}:
        return low, high * (4 if procedure == 'botox' else 2)
    if currency in {'KWD', 'BHD', 'OMR'}:
        return max(1, min(low, low / 4)), high / 2
    if currency == 'GBP' and procedure == 'breast_augmentation':
        low = max(low, 4000)
    return low, high


def procedure_amount_is_plausible(amount, currency, procedure, evidence=''):
    if not math.isfinite(amount) or amount <= 0:
        return False
    low, high = plausible_amount_band(currency, procedure)
    text = (evidence or '').replace('\u00a0', ' ').lower()
    currency = (currency or '').strip().upper()
    # A graft quantity or FUE label alone never makes a total a unit rate.
    per_graft = (procedure == 'hair_transplant'
                 and re.search(r'per\s+graft|/graft|per\s+follicle|/follicle|'
                               r'لكل\s+بصيلة|للبصيلة|per\s+grafturi', text)
                 and not re.search(r'effective\s+cost\s+per\s+graft|'
                                   r'lowest\s+effective\s+cost|works\s+out\s+(?:at|to|between)|'
                                   r'per\s+graft\s+at\s+full', text))
    if per_graft:
        low, high = 1, {
            'TRY': 500, 'TL': 500, 'AED': 150, 'RON': 250, 'LEI': 250,
            'PLN': 400, 'RUB': 5000, 'KRW': 8000, 'JPY': 5000, 'HKD': 150,
            'INR': 200, 'SGD': 50, 'THB': 500,
        }.get(currency, 100)
    if procedure == 'botox' and re.search(
            r'(?:per|/)\s*units?\b|(?:per|/)\s*iu\b|\b1\s*units?\b|'
            r'\b1\s*unitate|\bpe\s+unitate|/\s*unitate|\(\s*1\s*unit', text):
        low, high = 5, (400 if currency in {'RON', 'LEI', 'MDL', 'HUF'} else 150)
    return low <= amount <= high
