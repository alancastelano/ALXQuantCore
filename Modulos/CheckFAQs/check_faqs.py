# -*- coding: utf-8 -*-
"""
Monitor de alterações em mesas proprietárias
Monitora FAQ, regras, preços e possíveis descontos.

Arquivo único. Dados salvos na mesma pasta.
"""

import json
import hashlib
import difflib
import os
import random
import re
import time
from pathlib import Path
from datetime import datetime
from urllib.parse import urljoin, urlparse, parse_qsl, urlencode, urlunparse

from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout


# ============================================================
# CONFIGURAÇÃO GERAL
# ============================================================

HEADLESS = True  # Se algum site bloquear headless, teste False

_HERE = Path(__file__).resolve().parent
DATA_FILE = str(_HERE / "prop_monitor_data.json")
DISCOVERY_FILE = str(_HERE / "prop_discovered_pages.json")
LOG_FILE = str(_HERE / "prop_alteracoes.log")

# Opcional: Telegram
TELEGRAM_BOT_TOKEN = ""
TELEGRAM_CHAT_ID = ""

# Quantas páginas por tipo a descoberta automática pode usar
MAX_PAGES_PER_TYPE = 2

# Monitorar homepage apenas para descontos/promoções
CHECK_HOME_DISCOUNTS = True

# Se True, roda a descoberta automática novamente.
# Se False, usa o que já foi salvo em prop_discovered_pages.json
REFRESH_DISCOVERY = False

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
]

STATE_VERSION = "2.0"

TRACKING_PARAMS = {
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "fbclid", "gclid", "msclkid", "yclid", "mc_cid", "mc_eid",
    "ref", "referral", "affiliate", "aff", "_ga", "_gl",
}

NOISE_SELECTORS = [
    "nav", "footer", "header",
    "[role='navigation']", "[role='banner']", "[role='contentinfo']",
    ".newsletter", ".popup", ".modal", ".chat-widget",
    "#chat-widget", ".intercom-launcher",
    "[class*='newsletter']", "[class*='popup']",
    "[class*='cookie']", "[id*='cookie']",
    "script", "style", "noscript", "svg", "iframe", "template",
    "aside",
]

# ============================================================
# LISTA DE MESAS
# ============================================================
# Você pode deixar pages vazio para o sistema tentar descobrir sozinho.
# Depois, se quiser mais precisão, preencha pages manualmente.
#
# Exemplo manual:
#
# {
#     "name": "FTMO",
#     "home": "https://www.ftmo.com",
#     "pages": [
#         {
#             "type": "faq",
#             "url": "https://www.ftmo.com/en/faq/",
#             "selector": "main",
#             "click_selectors": ["button[aria-expanded='false']"]
#         },
#         {
#             "type": "pricing",
#             "url": "https://www.ftmo.com/en/pricing/",
#             "selector": "main",
#             "click_selectors": []
#         }
#     ]
# }

FIRMS = [
    {"name": "The5ers", "home": "https://www.the5ers.com", "pages": []},
    {"name": "FundedNext", "home": "https://www.fundednext.com", "pages": []},
    {"name": "FundingPips", "home": "https://www.fundingpips.com", "pages": []},
    {"name": "Alpha Capital", "home": "https://www.alphacapital.co.uk", "pages": []},
    {"name": "Goat Funded Trader", "home": "https://www.goatfundedtrader.com", "pages": []},
    {"name": "E8 Markets", "home": "https://www.e8markets.com", "pages": []},
    {"name": "FTMO", "home": "https://www.ftmo.com", "pages": []},
    {"name": "Maven", "home": "https://www.mavenfunded.com", "pages": []},
    {"name": "Blue Guardian", "home": "https://www.blueguardian.com", "pages": []},
    {"name": "Audacity Capital", "home": "https://www.audacitycapital.com", "pages": []},
    {"name": "Funded Trading Plus", "home": "https://www.fundedtradingplus.com", "pages": []},
    # Confira o domínio correto do Hantec Trader. Deixei um provável para você ajustar.
    {"name": "Hantec Trader", "home": "https://www.hantecmarkets.com", "pages": []},
    {"name": "The Trading Pit", "home": "https://www.thetradingpit.com", "pages": []},
    {"name": "Moneta Funded", "home": "https://www.monetafunded.com", "pages": []},
    {"name": "Axi Select", "home": "https://www.axiselect.com", "pages": []},
    {"name": "FXIFY", "home": "https://www.fxify.com", "pages": []},
]


# ============================================================
# PALAVRAS PARA DESCOBERTA AUTOMÁTICA
# ============================================================

FAQ_KEYWORDS = [
    "faq", "help", "support", "question", "questions",
    "rules", "rule", "terms", "condition", "conditions",
    "policy", "policies", "trading-rules", "guidelines",
    "frequently"
]

PRICE_KEYWORDS = [
    "price", "pricing", "prices", "plans", "plan",
    "challenge", "challenges", "evaluation", "account",
    "accounts", "program", "programs", "buy", "checkout",
    "funding", "funded", "get-started", "start"
]

DISCOUNT_KEYWORDS = [
    "discount", "promo", "promotion", "coupon",
    "offer", "sale", "black-friday", "blackfriday",
    "bonus", "deal", "cupom", "oferta", "desconto"
]

SKIP_EXTENSIONS = (
    ".pdf", ".png", ".jpg", ".jpeg", ".webp", ".svg",
    ".gif", ".zip", ".mp4", ".webm", ".csv", ".xls", ".xlsx"
)

COOKIE_BUTTON_SELECTORS = [
    "#onetrust-accept-btn-handler",
    "#accept-recommended-btn-handler",
    ".fc-cta-consent",
    "#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll",
    "button:has-text('Accept all')",
    "button:has-text('Accept')",
    "button:has-text('Aceitar')",
    "button:has-text('Aceitar todos')",
    "button:has-text('I agree')",
    "button:has-text('Concordo')",
    "button:has-text('Allow all')",
    "button:has-text('Permitir todos')",
]

COOKIE_CSS = [
    "[id*=cookie]",
    "[class*=cookie]",
    "[id*=consent]",
    "[class*=consent]",
    "#onetrust-consent-sdk",
    "#CybotCookiebotDialog",
    "#cookie-law-info-bar",
    ".cc-window",
    ".cc-banner",
    "[aria-label*='cookie']",
]

CURRENCY_RE = re.compile(
    r"(?:(?P<sym>[$€£¥₩])\s?(?P<val>\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{2})?))"
    r"|(?:\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{2})?\s?(?P<cur>USD|EUR|GBP|BRL|AUD|CAD|CHF|JPY))"
    r"|(?:USD|EUR|GBP|BRL|AUD|CAD|CHF|JPY)\s?\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{2})?",
    re.I
)

PRICE_RANGE_RE = re.compile(
    r"(?:from\s+|starting\s+(?:at\s+)?)?[$€£¥₩]?\s?\d[\d.,]*"
    r"\s*(?:[-–—]|(?:to|–|until)\s+)[$€£¥₩]?\s?\d[\d.,]*",
    re.I
)

VERSION_GUARD = re.compile(r"^(?:v?\d+(?:\.\d+)+|version\s+\d)", re.I)

PRICE_CONTEXT_RE = re.compile(
    r"\b(?:price|pricing|fee|cost|plan|challenge|evaluation|account|program|"
    r"refund|renew|reset|monthly|one[-\s]?time|payment|pay|buy|checkout|"
    r"total|valor|preço|preco|plano|conta|taxa|subscription|assinatura)\b",
    re.I
)

DISCOUNT_RE = re.compile(
    r"("
    r"\d{1,3}\s*%\s*(?:off|discount|desconto|de desconto|promo|promotion|coupon|cupom|voucher|sale|oferta)"
    r"|(?:off|discount|desconto|promo|promotion|coupon|cupom|voucher|sale|oferta)[^\n]{0,140}?\d{1,3}\s*%"
    r"|\b(?:discount|promo|promotion|coupon|cupom|voucher|sale|oferta|desconto|black\s?friday)\b"
    r"|use\s+(?:code|cupom|código)[^\n]{0,60}?\b[A-Z0-9]{4,}\b"
    r"|\b(?:limited\s+time|ends?\s+(?:in|on|at)|hurry|last\s+chance|expires?\s+(?:in|on))\b"
    r"|\bsave\s+(?:big|upto|up\s+to|at\s+least|\$|€|£)\b"
    r")",
    re.I
)


# ============================================================
# FUNÇÕES BÁSICAS
# ============================================================

def log(message):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] {message}"
    print(line)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def load_json(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        log(f"Erro ao ler {path}: {e}")
        return {}


def save_json(path, data):
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception as e:
        log(f"Erro ao salvar {path}: {e}")


def normalize_url(url):
    if not url:
        return ""
    try:
        parsed = urlparse(url.strip())
    except Exception:
        return url.strip()

    if parsed.scheme not in ("http", "https"):
        return url.strip()

    netloc = parsed.netloc.lower()
    if netloc.startswith("www."):
        netloc = netloc[4:]
    if ":80" in netloc and parsed.scheme == "http":
        netloc = netloc.replace(":80", "")
    if ":443" in netloc and parsed.scheme == "https":
        netloc = netloc.replace(":443", "")

    path = parsed.path or "/"
    if path != "/":
        path = path.rstrip("/")
    else:
        path = ""

    query_items = parse_qsl(parsed.query, keep_blank_values=True)
    query_items = [
        (k, v) for k, v in query_items
        if k.lower() not in TRACKING_PARAMS
    ]
    clean = urlunparse((
        parsed.scheme.lower(),
        netloc,
        path,
        parsed.params,
        urlencode(query_items),
        ""
    ))
    return clean or f"{parsed.scheme.lower()}://{netloc}"


def canonical_page_key(page_type, url):
    page_type = (page_type or "generic").strip().lower()
    url = normalize_url(url)
    return f"{page_type}|{url}"


def migrate_state_keys(state):
    if not isinstance(state, dict):
        return {}

    migrated = {}
    for firm_name, firm_state in state.items():
        if not isinstance(firm_state, dict):
            continue
        normalized = {}
        for raw_key, item in firm_state.items():
            if not isinstance(item, dict):
                continue
            page_type = str(item.get("type", "generic") or "generic").strip().lower()
            url = item.get("url") or raw_key.split("|", 1)[1] if "|" in raw_key else ""
            canonical_key = canonical_page_key(page_type, url)
            normalized[canonical_key] = item
        migrated[firm_name] = normalized
    return migrated


def send_telegram(message):
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        return

    import requests

    chunks = chunk_message(message, max_size=3800)

    for chunk in chunks:
        url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
        payload = {
            "chat_id": TELEGRAM_CHAT_ID,
            "text": chunk,
        }
        try:
            requests.post(url, json=payload, timeout=15)
        except Exception as e:
            log(f"Erro ao enviar Telegram: {e}")


def chunk_message(message, max_size=3800):
    lines = message.split("\n")
    chunks = []
    current = ""
    for line in lines:
        if len(current) + len(line) + 1 > max_size:
            if current:
                chunks.append(current)
            current = line
        else:
            current = current + "\n" + line if current else line
    if current:
        chunks.append(current)
    return chunks


def similarity_ratio(old_text, new_text):
    if not old_text or not new_text:
        return 0.0
    return difflib.SequenceMatcher(None, old_text, new_text).ratio()


def extract_price_value(line):
    m = re.search(r"(?:[$€£¥₩]\s?)?(\d[\d.,]*)\s?(?:USD|EUR|GBP|BRL|AUD|CAD|CHF|JPY)?", line)
    if not m:
        return None
    raw = m.group(1)
    if "." in raw and "," in raw:
        if raw.rindex(".") > raw.rindex(","):
            raw = raw.replace(",", "")
        else:
            raw = raw.replace(".", "").replace(",", ".")
    elif "," in raw:
        parts = raw.split(",")
        if len(parts[-1]) == 2:
            raw = raw.replace(",", ".")
        else:
            raw = raw.replace(",", "")
    try:
        return float(raw)
    except ValueError:
        return None


def extract_banner_texts(soup):
    banners = soup.select("img[alt], img[title]")
    texts = []
    for img in banners:
        alt = (img.get("alt") or "").strip()
        title = (img.get("title") or "").strip()
        for txt in (alt, title):
            if txt and DISCOUNT_RE.search(txt):
                texts.append(f"[banner] {txt}")
    return texts


def migrate_state(state):
    if not isinstance(state, dict):
        return {}
    version = state.get("__version__", "1.0")
    if version != STATE_VERSION:
        log(f"Migrando estado de {version} para {STATE_VERSION}")
        for firm_name, firm_state in state.items():
            if not isinstance(firm_state, dict):
                continue
            for key, page_state in firm_state.items():
                if not isinstance(page_state, dict):
                    continue
                page_state["hash"] = None
                page_state["needs_rebaseline"] = True
        state["__version__"] = STATE_VERSION
    return state


DYNAMIC_PATTERNS = [
    re.compile(r"\b\d{1,3}\s+(?:people|users|traders|visitors)\s+(?:online|viewing)\b", re.I),
    re.compile(r"\b(?:last\s+updated|updated\s+on|atualizado\s+em)\s*[:\-]?\s*[\w\s,:]+\b", re.I),
    re.compile(r"\b\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}(?::\d{2})?\b"),
    re.compile(r"\bcsrf[_\-]?(?:token|nonce)\b[^\n]{0,80}", re.I),
    re.compile(r"data-(?:csrf|nonce|session|token)[=\"'\s]+[a-zA-Z0-9_\-]+", re.I),
    re.compile(r"\bview[_\-]?state[=\"'\s]+[a-zA-Z0-9+/=]+", re.I),
    re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM|am|pm)\b"),
    re.compile(r"\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w*\s+\d{1,2},?\s+\d{4}\b", re.I),
]


def normalize_for_hash(text):
    for pat in DYNAMIC_PATTERNS:
        text = pat.sub("[DYNAMIC]", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text


def compute_hash(text):
    normalized = normalize_for_hash(text)
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


# ============================================================
# MESAS CADASTRADAS PELO USUÁRIO (sem editar o código)
# ============================================================

USER_FIRMS_FILE = str(_HERE / "user_firms.json")


def load_firms():
    """Mescla as mesas fixas (FIRMS) com as cadastradas pelo usuário."""
    firms = list(FIRMS)
    if not os.path.exists(USER_FIRMS_FILE):
        return firms
    data = load_json(USER_FIRMS_FILE) or {}
    extra = data.get("firms", []) or []
    seen = {str(f.get("name", "")).strip() for f in firms if f.get("name")}
    for f in extra:
        if not isinstance(f, dict):
            continue
        name = str(f.get("name", "")).strip()
        if name and name not in seen:
            firms.append(f)
            seen.add(name)
    return firms


def add_user_firm(name, home):
    """Adiciona uma mesa ao arquivo de cadastro do usuário.

    Retorna (ok, mensagem).
    """
    name = (name or "").strip()
    home = (home or "").strip()
    if not name or not home:
        return False, "nome e url obrigatorios"
    if not (home.startswith("http://") or home.startswith("https://")):
        return False, "url deve comecar com http:// ou https://"
    data = load_json(USER_FIRMS_FILE)
    firms = data.get("firms", [])
    if any(f.get("name") == name for f in firms):
        return False, "mesa ja cadastrada"
    firms.append({"name": name, "home": home, "pages": []})
    data["firms"] = firms
    save_json(USER_FIRMS_FILE, data)
    return True, "mesa adicionada"


def normalize_line(line):
    line = re.sub(r"\s+", " ", line).strip()
    return line[:220]


def normalize_text(text):
    lines = [re.sub(r"\s+", " ", line).strip() for line in text.splitlines()]
    lines = [line for line in lines if line]
    return "\n".join(lines)


def get_diff(old_text, new_text, label):
    old_lines = old_text.splitlines() if old_text else []
    new_lines = new_text.splitlines() if new_text else []

    diff = difflib.unified_diff(
        old_lines,
        new_lines,
        fromfile=f"{label} antigo",
        tofile=f"{label} atual",
        lineterm=""
    )
    return list(diff)


def compare_lists(old_list, new_list):
    old_list = old_list or []
    new_list = new_list or []

    old_map = {item.casefold(): item for item in old_list}
    new_map = {item.casefold(): item for item in new_list}

    added = [new_map[k] for k in new_map if k not in old_map]
    removed = [old_map[k] for k in old_map if k not in new_map]

    return added, removed


def compare_prices_semantic(old_list, new_list):
    old_list = old_list or []
    new_list = new_list or []

    old_prices = {}
    for item in old_list:
        v = extract_price_value(item)
        if v is not None:
            old_prices[v] = item

    new_prices = {}
    for item in new_list:
        v = extract_price_value(item)
        if v is not None:
            new_prices[v] = item

    added = []
    removed = []
    changed = []

    for val, line in new_prices.items():
        matched = False
        for old_val, old_line in old_prices.items():
            if old_val == val:
                matched = True
                break
            if old_val and val and abs(old_val - val) / max(old_val, val) < 0.5:
                changed.append((old_line, line))
                matched = True
                break
        if not matched:
            added.append(line)

    for val, line in old_prices.items():
        if val not in new_prices:
            if not any(line == old_l for old_l, _ in changed):
                removed.append(line)

    return added, removed, changed


# ============================================================
# EXTRAÇÃO DE CONTEÚDO
# ============================================================

def extract_text(html, selector="auto"):
    soup = BeautifulSoup(html, "html.parser")

    for sel in NOISE_SELECTORS:
        try:
            for el in soup.select(sel):
                el.decompose()
        except Exception:
            pass

    for css in COOKIE_CSS:
        try:
            for el in soup.select(css):
                el.decompose()
        except Exception:
            pass

    if selector and selector not in ("auto", "", "body"):
        root = soup.select_one(selector) or soup.body or soup
    else:
        root = (
            soup.select_one("main")
            or soup.select_one('[role="main"]')
            or soup.select_one("#main")
            or soup.select_one("#content")
            or soup.select_one(".main-content")
            or soup.body
            or soup
        )

    text = root.get_text("\n", strip=True)
    return normalize_text(text)


def extract_price_lines(text):
    out = []
    seen = set()

    for raw_line in text.splitlines():
        line = normalize_line(raw_line)
        if not line:
            continue

        if VERSION_GUARD.match(line):
            continue

        if CURRENCY_RE.search(line) or PRICE_RANGE_RE.search(line):
            if PRICE_CONTEXT_RE.search(line) or len(line) <= 80:
                key = line.casefold()
                if key not in seen:
                    seen.add(key)
                    out.append(line)

    return sorted(out)


def extract_discount_lines(text):
    out = []
    seen = set()

    for raw_line in text.splitlines():
        line = normalize_line(raw_line)
        if not line:
            continue

        if DISCOUNT_RE.search(line):
            key = line.casefold()
            if key not in seen:
                seen.add(key)
                out.append(line)

    return sorted(out)


# ============================================================
# PLAYWRIGHT / ACESSO A PÁGINAS
# ============================================================

def accept_cookies(page):
    for sel in COOKIE_BUTTON_SELECTORS:
        try:
            loc = page.locator(sel).first
            if loc.is_visible():
                loc.click(timeout=1500)
                page.wait_for_timeout(800)
                return
        except Exception:
            pass


def remove_noise_dom(page):
    try:
        page.evaluate("""
        () => {
            const selectors = [
                "[id*=cookie]",
                "[class*=cookie]",
                "[id*=consent]",
                "[class*=consent]",
                "#onetrust-consent-sdk",
                "#CybotCookiebotDialog",
                "#cookie-law-info-bar",
                ".cc-window",
                ".cc-banner",
                "[aria-label*='cookie']"
            ];

            selectors.forEach(sel => {
                document.querySelectorAll(sel).forEach(el => el.remove());
            });
        }
        """)
    except Exception:
        pass


def scroll_page(page, rounds=3):
    try:
        for _ in range(rounds):
            page.evaluate("window.scrollBy(0, document.body.scrollHeight)")
            page.wait_for_timeout(500)
    except Exception:
        pass


def expand_all_collapsibles(page):
    selectors = [
        "button[aria-expanded='false']",
        "[data-bs-toggle='collapse']:not([aria-expanded='true'])",
        "[data-toggle='collapse']:not(.collapsed)",
        ".accordion-button.collapsed",
        ".accordion__header:not(.is-open)",
        "[role='button'][aria-expanded='false']",
        "details:not([open]) > summary",
        ".faq-item:not(.active) .faq-question",
        ".accordion-title",
    ]

    for sel in selectors:
        try:
            locator = page.locator(sel)
            count = locator.count()
            for i in range(min(count, 50)):
                try:
                    el = locator.nth(i)
                    if el.is_visible():
                        el.click(timeout=2000)
                        page.wait_for_timeout(300)
                except Exception:
                    continue
        except Exception:
            continue

    try:
        page.evaluate("""
            document.querySelectorAll('details:not([open])').forEach(d => d.open = true)
        """)
    except Exception:
        pass


def click_elements(page, selectors):
    if not selectors:
        return

    for sel in selectors:
        try:
            locator = page.locator(sel)
            count = locator.count()

            for i in range(min(count, 30)):
                try:
                    locator.nth(i).click(timeout=1200)
                    page.wait_for_timeout(200)
                except Exception:
                    pass
        except Exception:
            pass


def fetch_html(context, url, click_selectors=None, content_selector=None, max_retries=3):
    for attempt in range(max_retries):
        html, status = _fetch_html_once(context, url, click_selectors, content_selector)
        if status < 400 and html:
            return html, status
        if status in (403, 429):
            wait = (2 ** attempt) + random.uniform(0, 1)
            log(f"    Rate limited ({status}), aguardando {wait:.1f}s...")
            time.sleep(wait)
        elif status >= 500:
            time.sleep(2 ** attempt)
        else:
            break
    return html, status


def _fetch_html_once(context, url, click_selectors=None, content_selector=None):
    page = context.new_page()

    try:
        response = page.goto(
            url,
            wait_until="domcontentloaded",
            timeout=60000
        )

        status = response.status if response else 999

        if status >= 400:
            return "", status

        if content_selector:
            try:
                page.wait_for_selector(content_selector, timeout=10000, state="visible")
            except PlaywrightTimeout:
                log(f"    Seletor de conteudo nao apareceu: {content_selector}")
        else:
            try:
                page.wait_for_load_state("networkidle", timeout=8000)
            except Exception:
                page.wait_for_timeout(2000)

        accept_cookies(page)
        remove_noise_dom(page)

        if click_selectors:
            click_elements(page, click_selectors)

        expand_all_collapsibles(page)

        scroll_page(page)

        page.wait_for_timeout(500)
        remove_noise_dom(page)

        html = page.content()
        return html, status

    except PlaywrightTimeout:
        log(f"Timeout ao acessar: {url}")
        return "", 999

    except Exception as e:
        log(f"Erro ao acessar {url}: {e}")
        return "", 999

    finally:
        page.close()


# ============================================================
# DESCOBERTA AUTOMÁTICA DE PÁGINAS
# ============================================================

COMMON_PATHS = [
    "/faq", "/faqs", "/help", "/support", "/questions",
    "/pricing", "/price", "/plans", "/challenge", "/challenges",
    "/evaluation", "/rules", "/terms", "/terms-and-conditions",
    "/trading-rules", "/funding-rules", "/program-rules",
    "/discount", "/promo", "/promotion", "/coupon",
    "/offer", "/sale", "/bonus",
]

PATH_TYPE_HINTS = {
    "/faq": "faq", "/faqs": "faq", "/help": "faq", "/support": "faq",
    "/questions": "faq", "/rules": "faq", "/terms": "faq",
    "/terms-and-conditions": "faq", "/trading-rules": "faq",
    "/funding-rules": "faq", "/program-rules": "faq",
    "/pricing": "pricing", "/price": "pricing", "/plans": "pricing",
    "/challenge": "pricing", "/challenges": "pricing",
    "/evaluation": "pricing",
    "/discount": "promo", "/promo": "promo", "/promotion": "promo",
    "/coupon": "promo", "/offer": "promo", "/sale": "promo",
    "/bonus": "promo",
}


def discover_via_sitemap(context, sitemap_url, home):
    html, status = fetch_html(context, sitemap_url, [])
    if status >= 400 or not html:
        return []

    soup = BeautifulSoup(html, "xml") if html.strip().startswith("<?xml") else BeautifulSoup(html, "html.parser")
    urls = []

    for sitemap in soup.find_all("sitemap"):
        loc = sitemap.find("loc")
        if loc:
            urls.extend(discover_via_sitemap(context, loc.text.strip(), home))

    parsed_home = urlparse(home)
    base_netloc = parsed_home.netloc.replace("www.", "")

    for url_tag in soup.find_all("url"):
        loc = url_tag.find("loc")
        if loc:
            url = loc.text.strip()
            parsed = urlparse(url)
            netloc = parsed.netloc.replace("www.", "")
            if netloc == base_netloc or netloc.endswith("." + base_netloc):
                urls.append(url)

    return urls


def discover_common_paths(context, firm):
    home = firm.get("home")
    if not home:
        return []

    candidates = []

    for path in COMMON_PATHS:
        url = urljoin(home, path)
        try:
            page = context.new_page()
            response = page.goto(url, wait_until="domcontentloaded", timeout=15000)
            status = response.status if response else 999
            page.close()

            if status < 400:
                page_type = PATH_TYPE_HINTS.get(path, "generic")
                candidates.append({
                    "type": page_type,
                    "url": normalize_url(url),
                    "selector": "auto",
                    "click_selectors": [],
                    "check_text_diff": page_type in ("faq", "pricing"),
                    "score": 5
                })
        except Exception:
            continue

    return candidates

def score_link(url, text, aria):
    target = f"{url} {text} {aria}".lower()

    def count_keyword(keyword, text, weight=2):
        return len(re.findall(rf"\b{re.escape(keyword)}\b", text)) * weight

    faq = sum(count_keyword(w, target) for w in FAQ_KEYWORDS)
    pricing = sum(count_keyword(w, target) for w in PRICE_KEYWORDS)
    discount = sum(count_keyword(w, target) for w in DISCOUNT_KEYWORDS)

    if "/faq" in target or "faq" in target:
        faq += 4

    if any(x in target for x in [
        "/pricing", "/price", "/plans", "/plan",
        "/challenge", "/challenges", "/evaluation",
        "/account", "/accounts"
    ]):
        pricing += 4

    if any(x in target for x in [
        "/discount", "/promo", "/promotion", "/coupon",
        "/offer", "/sale", "/bonus"
    ]):
        discount += 4

    return faq, pricing, discount


def discover_pages(context, firm):
    home = firm.get("home")
    if not home:
        return []

    all_candidates = []

    parsed_home = urlparse(home)
    base_netloc = parsed_home.netloc.replace("www.", "")

    for sitemap_url in [f"{home}/sitemap.xml", f"{home}/sitemap_index.xml"]:
        sitemap_urls = discover_via_sitemap(context, sitemap_url, home)
        for surl in sitemap_urls:
            path_lower = urlparse(surl).path.lower()
            if any(path_lower.endswith(ext) for ext in SKIP_EXTENSIONS):
                continue
            matched_type = None
            for hint_path, hint_type in PATH_TYPE_HINTS.items():
                if hint_path in path_lower:
                    matched_type = hint_type
                    break
            if matched_type:
                all_candidates.append({
                    "type": matched_type,
                    "url": normalize_url(surl),
                    "selector": "auto",
                    "click_selectors": [],
                    "check_text_diff": matched_type in ("faq", "pricing"),
                    "score": 6
                })

    common = discover_common_paths(context, firm)
    all_candidates.extend(common)

    html, status = fetch_html(context, home, [])
    if status >= 400:
        return _dedupe_and_limit(all_candidates, home)

    soup = BeautifulSoup(html, "html.parser")

    for a in soup.find_all("a", href=True):
        href = a.get("href", "").strip()

        if not href:
            continue

        if href.startswith(("javascript:", "mailto:", "tel:", "#")):
            continue

        absolute = urljoin(home, href)
        parsed = urlparse(absolute)

        if parsed.scheme not in ("http", "https"):
            continue

        netloc = parsed.netloc.replace("www.", "")

        if not (netloc == base_netloc or netloc.endswith("." + base_netloc)):
            continue

        path_lower = parsed.path.lower()
        if any(path_lower.endswith(ext) for ext in SKIP_EXTENSIONS):
            continue

        text = a.get_text(" ", strip=True)
        aria = a.get("aria-label", "") or ""

        faq_score, price_score, discount_score = score_link(absolute, text, aria)

        chosen_type = None
        score = 0

        if faq_score >= 5 and faq_score >= price_score and faq_score >= discount_score:
            chosen_type = "faq"
            score = faq_score

        elif price_score >= 5 and price_score >= faq_score and price_score >= discount_score:
            chosen_type = "pricing"
            score = price_score

        elif discount_score >= 6:
            chosen_type = "promo"
            score = discount_score

        if not chosen_type:
            continue

        clean_url = normalize_url(absolute)

        if not clean_url or clean_url == normalize_url(home):
            continue

        all_candidates.append({
            "type": chosen_type,
            "url": clean_url,
            "selector": "body" if chosen_type == "promo" else "auto",
            "click_selectors": [],
            "check_text_diff": chosen_type in ("faq", "pricing"),
            "score": score
        })

    return _dedupe_and_limit(all_candidates, home)


def _dedupe_and_limit(candidates, home):
    dedupe = {}
    for item in candidates:
        key = canonical_page_key(item["type"], item["url"])
        if key not in dedupe or item.get("score", 0) > dedupe[key].get("score", 0):
            dedupe[key] = item

    pages = []

    if CHECK_HOME_DISCOUNTS:
        pages.append({
            "type": "homepage",
            "url": home,
            "selector": "body",
            "click_selectors": [],
            "check_text_diff": False
        })

    for page_type in ["faq", "pricing", "promo"]:
        typed = [
            item for item in dedupe.values()
            if item["type"] == page_type
        ]

        typed.sort(key=lambda x: x.get("score", 0), reverse=True)

        limit = 1 if page_type == "promo" else MAX_PAGES_PER_TYPE

        for item in typed[:limit]:
            pages.append({
                "type": item["type"],
                "url": item["url"],
                "selector": item["selector"],
                "click_selectors": item["click_selectors"],
                "check_text_diff": item["check_text_diff"]
            })

    return pages


def get_pages_for_firm(context, firm, discovery):
    name = firm["name"]

    if firm.get("pages"):
        return firm["pages"]

    if not firm.get("home"):
        return []

    if not REFRESH_DISCOVERY and name in discovery:
        return discovery[name]

    log(f"Descobrindo páginas automaticamente para {name}...")
    pages = discover_pages(context, firm)
    discovery[name] = pages

    return pages


# ============================================================
# VERIFICAÇÃO DE CADA PÁGINA
# ============================================================

def check_page(context, firm_name, page_cfg, state):
    url = page_cfg.get("url")
    if not url:
        return False

    page_type = page_cfg.get("type", "generic")
    selector = page_cfg.get("selector", "auto")
    click_selectors = page_cfg.get("click_selectors", [])
    check_text_diff = page_cfg.get("check_text_diff", True)

    canonical_url = normalize_url(url)
    key = canonical_page_key(page_type, canonical_url)

    log(f"  - {firm_name} | {page_type} | {canonical_url}")

    html, status = fetch_html(context, url, click_selectors)

    if status in (404, 410):
        firm_state = state.setdefault(firm_name, {})
        old = firm_state.get(key)
        if old and old.get("text"):
            alerts = [f"Pagina removida: {firm_name} | {page_type} | {url} (HTTP {status})"]
            header = f"🚨 {firm_name} | {page_type} | {url}\n"
            full_message = header + "\n".join(alerts)
            log(full_message)
            send_telegram(full_message)
            firm_state[key] = {
                **old,
                "changed": True,
                "last_checked": datetime.now().isoformat(),
                "removed": True,
            }
            return True
        log(f"    HTTP {status} - pulando.")
        return False

    if status >= 400:
        log(f"    HTTP {status} - pulando.")
        return False

    text = extract_text(html, selector)
    new_hash = compute_hash(text)

    prices = extract_price_lines(text)
    discounts = extract_discount_lines(text)

    now = datetime.now().isoformat()

    firm_state = state.setdefault(firm_name, {})
    old = firm_state.get(key)
    if not old:
        for existing_key, existing_item in firm_state.items():
            if not isinstance(existing_item, dict):
                continue
            if existing_item.get("type", "generic").lower() == page_type.lower():
                existing_url = normalize_url(existing_item.get("url") or "")
                if existing_url and existing_url == canonical_url:
                    old = existing_item
                    key = existing_key
                    break

    if not old:
        firm_state[key] = {
            "url": canonical_url,
            "type": page_type,
            "hash": new_hash,
            "text": text if check_text_diff else "",
            "previous_text": "",
            "changed": False,
            "prices": prices,
            "previous_prices": [],
            "discounts": discounts,
            "previous_discounts": [],
            "last_checked": now,
            "last_changed": now,
            "is_baseline": True,
        }
        log("    Primeira leitura registrada (baseline).")
        return False

    if old.get("removed"):
        log("    Pagina anteriormente removida agora esta acessivel novamente.")
        old.pop("removed", None)

    alerts = []

    old_hash = old.get("hash")

    if old_hash and new_hash and old_hash != new_hash:
        if check_text_diff:
            old_text = old.get("text", "")
            sim = similarity_ratio(old_text, text)
            if sim > 0.98:
                log(f"    Mudanca minima ({sim:.1%}) - provavelmente ruido.")
                firm_state[key] = {
                    **old,
                    "hash": new_hash,
                    "last_checked": now,
                }
                return False

            old_len = len(old_text)
            new_len = len(text)
            if old_len > 1000 and new_len < old_len * 0.3:
                alerts.insert(0, f"Conteudo reduzido drasticamente ({old_len} -> {new_len} chars). Possivel quebra de seletor.")

            diff = get_diff(old_text, text, f"{firm_name} {page_type}")
            if diff:
                alerts.append(f"Texto alterado em {page_type}: {url}")
                changes_only = [ln for ln in diff if ln.startswith(("+", "-")) and not ln.startswith(("+++", "---"))]
                alerts.extend(changes_only[:100])
                if len(changes_only) > 100:
                    alerts.append(f"... e mais {len(changes_only) - 100} alteracoes")

    price_added, price_removed, price_changed = compare_prices_semantic(old.get("prices", []), prices)
    discount_added, discount_removed = compare_lists(old.get("discounts", []), discounts)

    if price_added or price_removed or price_changed:
        alerts.append("Possiveis precos alterados:")
        for item in price_added:
            alerts.append(f"  + {item}")
        for item in price_removed:
            alerts.append(f"  - {item}")
        for old_p, new_p in price_changed:
            alerts.append(f"  ~ {old_p} -> {new_p}")

    if discount_added or discount_removed:
        alerts.append("Possiveis descontos/promocoes alterados:")
        for item in discount_added:
            alerts.append(f"  + {item}")
        for item in discount_removed:
            alerts.append(f"  - {item}")

    firm_state[key] = {
        "url": canonical_url,
        "type": page_type,
        "hash": new_hash,
        "text": text if check_text_diff else "",
        "previous_text": old.get("text", "") if alerts else old.get("previous_text", ""),
        "changed": bool(alerts),
        "prices": prices,
        "previous_prices": old.get("prices", []) if alerts else old.get("previous_prices", []),
        "discounts": discounts,
        "previous_discounts": old.get("discounts", []) if alerts else old.get("previous_discounts", []),
        "last_checked": now,
        "last_changed": now if alerts else old.get("last_changed", now),
        "is_baseline": False,
    }

    if alerts:
        header = f"🚨 {firm_name} | {page_type} | {url}\n"
        full_message = header + "\n".join(alerts)

        log(full_message)
        send_telegram(full_message)

        return True

    log("    Sem alteracoes relevantes.")
    return False


# ============================================================
# ROTINA PRINCIPAL
# ============================================================

def main():
    log("=" * 60)
    log("Iniciando monitor de mesas proprietarias")

    state = load_json(DATA_FILE) or {}
    discovery = load_json(DISCOVERY_FILE) or {}
    if not isinstance(state, dict):
        state = {}
    if not isinstance(discovery, dict):
        discovery = {}
    state = migrate_state(state)

    any_change = False

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=HEADLESS,
            args=["--disable-blink-features=AutomationControlled"]
        )

        context = browser.new_context(
            user_agent=random.choice(USER_AGENTS),
            viewport={"width": 1366, "height": 900},
            locale="en-US"
        )

        try:
            for firm in load_firms():
                firm_name = firm.get("name", "Sem nome")

                if not firm.get("home") and not firm.get("pages"):
                    log(f"{firm_name}: sem home ou pages configuradas.")
                    continue

                log(f"Monitorando {firm_name}...")

                pages = get_pages_for_firm(context, firm, discovery)

                if not pages:
                    log(f"  Nenhuma pagina encontrada para {firm_name}.")
                    continue

                for page_cfg in pages:
                    changed = check_page(context, firm_name, page_cfg, state)
                    if changed:
                        any_change = True

                    time.sleep(2)

                save_json(DATA_FILE, state)
                save_json(DISCOVERY_FILE, discovery)

        finally:
            browser.close()

    save_json(DATA_FILE, state)
    save_json(DISCOVERY_FILE, discovery)

    if not any_change:
        log("Nenhuma alteracao relevante detectada.")

    log("Monitoramento concluido.")


if __name__ == "__main__":
    main()