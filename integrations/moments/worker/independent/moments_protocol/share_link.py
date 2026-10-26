"""Offline share-card projection; never fetch external previews or media URLs."""
import unicodedata
from urllib.parse import unquote, urlsplit

from .finder import _tree


def safe_web_url(value):
    """Keep original http(s) page URLs; reject browser-ambiguous/active inputs.

    Article query strings (including WeChat permalink signatures) are part of
    the original shared page URL. Media locators must never be passed here as
    a fallback. Known image/Finder CDN origins are rejected defensively.
    """
    if not isinstance(value, str) or not value or len(value) > 32768:
        return None
    if any(char.isspace() or unicodedata.category(char) in ("Cc", "Cf") for char in value):
        return None
    if "\\" in value:
        return None
    decoded = unquote(value)
    if any(unicodedata.category(char) in ("Cc", "Cf") for char in decoded):
        return None
    try:
        parts = urlsplit(value)
        if (parts.scheme.lower() not in ("http", "https") or not parts.netloc
                or not parts.hostname or parts.username is not None or parts.password is not None):
            return None
        parts.port  # A malformed or out-of-range port must not reach a browser.
        host = parts.hostname.encode("idna").decode("ascii").lower()
    except (ValueError, UnicodeError):
        return None
    if any(char in host for char in ("%", "<", ">", '"', "'")):
        return None
    if (host in ("wxapp.tc.qq.com", "wx.qlogo.cn", "finder.video.qq.com")
            or host.endswith((".qpic.cn", ".qlogo.cn"))):
        return None
    return value


def project_share_link(content, reference, media_references):
    """Use contentUrl exclusively as a share-card jump target, never media.url."""
    if content is None:
        return None, {}
    media = content.findall("mediaList/media")
    if content.findtext("type") not in ("3", "4") and not any(item.findtext("type") == "3" for item in media):
        return None, {}
    private = {reference: {"kind": "share_link", "private_ref": reference,
                            "tree": _tree(content)}}
    url = safe_web_url(content.findtext("contentUrl"))
    if url is None:
        return None, private
    title = content.findtext("title") or next((item.findtext("title") for item in media if item.findtext("title")), None)
    description = content.findtext("description") or next((item.findtext("description") for item in media if item.findtext("description")), None)
    thumbnail_ref = next((media_references[index] for index, item in enumerate(media)
                          if index < len(media_references)
                          and (item.findtext("thumb") or (item.findtext("type") == "2" and item.findtext("url")))), None)
    return {"kind": "web_link", "url": url, "title": title, "description": description,
            "thumbnail_ref": thumbnail_ref, "private_ref": reference}, private


def public_link_metadata(value):
    """Revalidate and deep-allowlist share metadata in current/historical exports."""
    if not isinstance(value, dict):
        return None
    url = safe_web_url(value.get("url"))
    if url is None:
        return None
    result = {"kind": "web_link", "url": url}
    for key in ("title", "description"):
        if value.get(key) is None or isinstance(value.get(key), str):
            result[key] = value.get(key)
    for key in ("thumbnail_ref", "private_ref"):
        item = value.get(key)
        if item is None or (isinstance(item, str) and "://" not in item
                            and not any(unicodedata.category(c) in ("Cc", "Cf") for c in item)):
            result[key] = item
    return result
