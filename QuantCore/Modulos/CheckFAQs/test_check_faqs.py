from Modulos.CheckFAQs.check_faqs import (
    canonical_page_key, normalize_url, normalize_for_hash, compute_hash,
    similarity_ratio, extract_price_value, chunk_message, extract_price_lines,
    extract_discount_lines, extract_text, score_link, compare_prices_semantic,
)


def test_normalize_url_removes_tracking_and_trailing_slash():
    url = "https://www.ftmo.com/en/faq/?utm_source=ads&ref=home#top"
    assert normalize_url(url) == "https://ftmo.com/en/faq"


def test_canonical_page_key_is_stable_for_same_page():
    a = canonical_page_key("faq", "https://www.ftmo.com/en/faq/?utm_source=ads")
    b = canonical_page_key("faq", "https://www.ftmo.com/en/faq")
    assert a == b == "faq|https://ftmo.com/en/faq"


def test_normalize_url_strips_www():
    assert normalize_url("https://www.ftmo.com/faq") == "https://ftmo.com/faq"


def test_normalize_url_ref_param_exact_match():
    url = "https://example.com/page?ref=home&reference=xyz"
    result = normalize_url(url)
    assert "ref=home" not in result
    assert "reference=xyz" in result


def test_normalize_for_hash_removes_dynamic_content():
    text1 = "Updated at 2024-01-15T10:30:00 Welcome to our site"
    text2 = "Updated at 2024-08-20T14:45:00 Welcome to our site"
    assert normalize_for_hash(text1) == normalize_for_hash(text2)


def test_normalize_for_hash_removes_online_counters():
    text1 = "42 traders online Welcome"
    text2 = "137 traders online Welcome"
    assert normalize_for_hash(text1) == normalize_for_hash(text2)


def test_compute_hash_ignores_dynamic_content():
    t1 = "Price: $99 Updated: 2024-01-15T10:30:00"
    t2 = "Price: $99 Updated: 2024-08-20T14:45:00"
    assert compute_hash(t1) == compute_hash(t2)


def test_similarity_ratio_identical():
    assert similarity_ratio("hello", "hello") == 1.0


def test_similarity_ratio_similar():
    s = similarity_ratio("hello world", "hello worlds")
    assert s > 0.9


def test_similarity_ratio_empty():
    assert similarity_ratio("", "text") == 0.0
    assert similarity_ratio("text", "") == 0.0


def test_extract_price_value_basic():
    assert extract_price_value("$99.99") == 99.99
    assert extract_price_value("$1,299.00") == 1299.00
    assert extract_price_value("99 USD") == 99.0


def test_extract_price_value_none_on_no_match():
    assert extract_price_value("no price here") is None


def test_chunk_message_respects_lines():
    msg = "Line 1\nLine 2\nLine 3"
    chunks = chunk_message(msg, max_size=12)
    assert len(chunks) >= 2
    for chunk in chunks:
        assert len(chunk) <= 12


def test_extract_price_lines_captures_ranges():
    text = "Plans from $97 to $499"
    lines = extract_price_lines(text)
    assert any("$97" in l for l in lines)


def test_extract_discount_lines_captures_urgency():
    text = "Limited time offer ends soon"
    lines = extract_discount_lines(text)
    assert len(lines) > 0


def test_extract_discount_lines_captures_coupons():
    text = "Use code SPRING50 for savings"
    lines = extract_discount_lines(text)
    assert len(lines) > 0


def test_score_link_uses_word_boundary():
    url1 = "https://example.com/software"
    url2 = "https://example.com/rules"
    f1, _, _ = score_link(url1, "Software", "")
    f2, _, _ = score_link(url2, "Rules", "")
    assert f2 > f1


def test_compare_prices_semantic_detects_change():
    old = ["Plan A - $97"]
    new = ["Plan A - $127"]
    added, removed, changed = compare_prices_semantic(old, new)
    assert len(changed) == 1
    assert ("Plan A - $97", "Plan A - $127") in changed


def test_compare_prices_semantic_detects_addition():
    old = ["Plan A - $97"]
    new = ["Plan A - $97", "Plan B - $197"]
    added, removed, changed = compare_prices_semantic(old, new)
    assert len(added) == 1
    assert "Plan B - $197" in added


def test_extract_text_removes_noise():
    html = "<html><body><nav>Nav</nav><main>Content</main><footer>Footer</footer></body></html>"
    text = extract_text(html, "auto")
    assert "Content" in text
    assert "Nav" not in text
    assert "Footer" not in text
