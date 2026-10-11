"""Read explicit marketplace tariff dates without executing website JavaScript.

Fetching a page today does not make a price last updated last year current.
Only a date explicitly attached to the selected fee, or its own tariff menu,
can support this age check. Undated offers keep their date unknown.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
import math
import re
import unicodedata

from bs4 import BeautifulSoup


MAX_MARKETPLACE_PRICE_AGE_DAYS = 365


def _fold(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value or "").casefold().split())


def _split_js_arguments(value: str) -> list[str]:
    """Split a literal argument list, honoring quoted commas and brackets."""
    parts: list[str] = []
    start = depth = 0
    quote = ""
    escaped = False
    for i, char in enumerate(value):
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = ""
        elif char in ('"', "'", "`"):
            quote = char
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and not depth:
            parts.append(value[start:i].strip())
            start = i + 1
    parts.append(value[start:].strip())
    return parts


def _closing(value: str, start: int, opener: str, closer: str) -> int | None:
    depth = 0
    quote = ""
    escaped = False
    for i in range(start, len(value)):
        char = value[i]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = ""
            continue
        if char in ('"', "'", "`"):
            quote = char
        elif char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return i
    return None


def _nuxt_literals(script: str) -> dict[str, object]:
    """Resolve only JSON-literal IIFE parameters; never eval website code."""
    header = re.search(r"window\.__NUXT__\s*=\s*\(function\(([^)]*)\)\s*\{", script)
    if not header:
        return {}
    end = _closing(script, header.end() - 1, "{", "}")
    if end is None:
        return {}
    call = re.match(r"\s*\(", script[end + 1:])
    if not call:
        return {}
    start = end + 1 + call.end() - 1
    finish = _closing(script, start, "(", ")")
    if finish is None:
        return {}
    params = header.group(1).split(",")
    args = _split_js_arguments(script[start + 1:finish])
    if len(params) != len(args):
        return {}
    result: dict[str, object] = {}
    for key, raw in zip(params, args):
        try:
            result[key.strip()] = json.loads(raw)
        except (ValueError, TypeError):
            # Expressions, function calls and object references are not dates.
            continue
    return result


def _fields(value: str, literals: dict[str, object]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, raw in re.findall(
            r'(?:^|,)\s*([A-Za-z_$][\w$]*)\s*:\s*("(?:\\.|[^"\\])*"|[^,{}]+)', value):
        raw = raw.strip()
        if raw in literals:
            result[key] = literals[raw]
        else:
            try:
                result[key] = json.loads(raw)
            except (ValueError, TypeError):
                continue
    return result


def _date(value: str) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    return parsed.replace(tzinfo=timezone.utc) if parsed.tzinfo is None else parsed.astimezone(timezone.utc)


def marketplace_price_date_failure(
        updated_at: str, date_basis: str = "", *, now: datetime | None = None) -> str:
    if date_basis == "ambiguous_menu_date":
        return "marketplace_price_date_ambiguous"
    if not updated_at:
        return ""
    date = _date(updated_at)
    if date is None:
        return "marketplace_price_date_invalid"
    clock = now or datetime.now(timezone.utc)
    clock = clock.replace(tzinfo=timezone.utc) if clock.tzinfo is None else clock.astimezone(timezone.utc)
    if date > clock + timedelta(days=1):
        return "marketplace_price_date_future"
    if (clock - date > timedelta(days=MAX_MARKETPLACE_PRICE_AGE_DAYS)
            and date_basis != "user_retained_published_fee"):
        return "marketplace_price_outdated"
    return ""


def _bookimed_date_context(html: str) -> tuple[str, list[tuple]]:
    """Keep only menu text and own fee metadata, never the full DOM or scripts."""
    soup = BeautifulSoup(html or "", "html.parser")
    menu = soup.find(id="prices")
    if menu is None:
        table = soup.select_one(".clinic-prices__table")
        menu = table.parent if table else None
    if menu is None:
        return "", []
    own_rows = menu.select("tr.clinic-prices__table-tr, tr")
    if not own_rows:
        return "", []
    # Some extractors add "treatment" or use a canonical family label. Bind
    # those variants to the actual table's service name in their own quote.
    own_names = {_fold(cell.get_text(" ", strip=True)) for row in own_rows
                 if (cell := row.find(["td", "th"])) is not None}
    dated_records = []
    for script_node in soup.find_all("script"):
        script = script_node.get_text()
        if "window.__NUXT__" not in script:
            continue
        literals = _nuxt_literals(script)
        clinic = re.search(r"content\s*:\s*\{clinic\s*:\s*\{id\s*:\s*([^,}]+)", script)
        if not clinic:
            continue
        clinic_id = _fields("id:" + clinic.group(1), literals).get("id")
        if clinic_id is None:
            continue
        records = re.finditer(
            r"\{operation:\{([^{}]*(?:name_forms:\{[^{}]*\}[^{}]*)?)\},prices:\{([^{}]*)\}\}", script)
        for record in records:
            operation = _fields(record.group(1), literals)
            price = _fields(record.group(2), literals)
            name = _fold(str(operation.get("name", "")))
            if (price.get("clinic_id") != clinic_id
                    or price.get("entity_id") != operation.get("id")
                    or price.get("entity") != "operations"
                    or name not in own_names):
                continue
            try:
                lower = float(price.get("price_from"))
                upper = float(price.get("price_to"))
            except (ValueError, TypeError):
                continue
            if not math.isfinite(lower) or not math.isfinite(upper):
                continue
            date = price.get("updated_at")
            if isinstance(date, str) and date.strip():
                dated_records.append((name, lower, upper, price.get("currency"), date))
    return menu.get_text(" ", strip=True), dated_records


def bookimed_price_date(
        html: str, procedure_label: str, minimum: float,
        maximum: float | None, currency: str, raw_evidence: str = "",
        memo: dict | None = None) -> tuple[str, str, str]:
    """Prefer a matching own-clinic price record over the menu summary date."""
    key = ("bookimed_source_dates", hashlib.sha256((html or "").encode()).digest())
    context = memo.get(key) if memo is not None else None
    if context is None:
        context = _bookimed_date_context(html)
        if memo is not None:
            memo[key] = context
    text, records = context
    label, bound_quote = _fold(procedure_label), _fold(raw_evidence)
    expected_upper = minimum if maximum is None else maximum
    dates = {date for name, lower, upper, code, date in records
             if code == currency and (name == label or name in bound_quote)
             and abs(lower - minimum) <= .011 and abs(upper - expected_upper) <= .011}
    if len(dates) == 1:
        date = next(iter(dates))
        return date, "updated_at=" + date, "provider_procedure_price_record"
    if len(dates) > 1:
        return "", "Conflicting updated_at values for the selected fee", "ambiguous_menu_date"
    explicit = re.search(r"Last\s+price\s+update\s*[-—:]?\s*(\d{1,4}[./-]\d{1,2}[./-]\d{1,4})", text, re.I)
    if not explicit:
        return "", "", ""
    raw = explicit.group(1)
    # Bookimed prints its documented DD.MM.YYYY menu date. ISO is unambiguous;
    # slash dates without a site-defined locale are not guessed.
    try:
        parsed = (datetime.strptime(raw, "%d.%m.%Y") if "." in raw
                  else datetime.strptime(raw, "%Y-%m-%d") if re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw)
                  else None)
    except ValueError:
        parsed = None
    if parsed is None:
        return "", explicit.group(0), "ambiguous_menu_date"
    return parsed.date().isoformat(), explicit.group(0), "provider_tariff_menu"
