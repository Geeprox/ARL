"""Offline Finder/Channels card metadata; locators and unknown XML stay private."""
import re


def _integer(value):
    if not isinstance(value, str) or re.fullmatch(r"[0-9]{1,128}", value, re.ASCII) is None:
        return None
    return int(value)


def _identifier(value):
    number = _integer(value)
    return str(number) if number is not None else None


def _tree(element):
    def node(source):
        return {"tag": source.tag, "attributes": dict(source.attrib),
                "text": source.text, "tail": source.tail, "children": []}
    result = node(element)
    pending = [(element, result)]
    while pending:
        source, target = pending.pop()
        for child in source:
            destination = node(child)
            target["children"].append(destination)
            pending.append((child, destination))
    return result


def project_finder_feed(content, reference):
    """Project the observed ContentObject/finderFeed shape without fetching URLs.

    Numeric identifiers stay decimal strings. Explicit author/description text
    is preserved, including original PUA/emoji characters. All unknown nodes,
    signed locators, objectNonceId and crypto fields remain in the private tree.
    """
    feed = content.find("finderFeed") if content is not None else None
    if feed is None:
        return None, {}
    public = {
        "kind": "finder_feed", "private_ref": reference,
        "object_id": _identifier(feed.findtext("objectId")),
        "feed_type": _integer(feed.findtext("feedType")),
        "author_username": feed.findtext("username"),
        "author_nickname": feed.findtext("nickname"),
        "description": feed.findtext("desc"),
        "media_count": _integer(feed.findtext("mediaCount")),
        "live_id": _identifier(feed.findtext("liveId")),
        "auth_icon_type": _integer(feed.findtext("authIconType")),
        "media": [],
    }
    private = {reference: {"kind": "finder_feed", "private_ref": reference,
                            "tree": _tree(feed)}}
    for index, element in enumerate(feed.findall("mediaList/media")):
        asset_id = reference + ":" + str(index)
        public["media"].append({
            "asset_id": asset_id, "private_ref": asset_id, "index": index,
            "media_type": _integer(element.findtext("mediaType")),
            "width": _integer(element.findtext("width")),
            "height": _integer(element.findtext("height")),
            "video_duration": _integer(element.findtext("videoPlayDuration")),
            "local_path": None, "poster_path": None, "backup_status": "missing_bytes",
        })
        private[asset_id] = {"kind": "finder_media", "private_ref": asset_id,
                             "index": index, "tree": _tree(element)}
    return public, private


def public_finder_metadata(value):
    """Deep allowlist for Agent export, including revisions of older archives."""
    if not isinstance(value, dict):
        return None
    result = {}
    for key in ("kind", "private_ref", "author_username", "author_nickname", "description"):
        item = value.get(key)
        if item is None or isinstance(item, str):
            result[key] = item
    for key in ("object_id", "live_id"):
        result[key] = _identifier(value.get(key))
    for key in ("feed_type", "media_count", "auth_icon_type"):
        item = value.get(key)
        if item is None or type(item) is int:
            result[key] = item
    result["media"] = []
    media = value.get("media", [])
    for source in media if isinstance(media, list) else []:
        if not isinstance(source, dict):
            continue
        item = {}
        for key in ("asset_id", "private_ref"):
            if isinstance(source.get(key), str):
                item[key] = source[key]
        for key in ("index", "media_type", "width", "height", "video_duration"):
            if source.get(key) is None or type(source.get(key)) is int:
                item[key] = source.get(key)
        for key in ("poster_width", "poster_height"):
            if type(source.get(key)) is int and source[key] > 0:
                item[key] = source[key]
        for key in ("local_path", "poster_path"):
            path = source.get(key)
            if path is None or (isinstance(path, str) and not path.startswith(("/", "\\"))
                                and ":" not in path and ".." not in path.replace("\\", "/").split("/")):
                item[key] = path
        status = source.get("backup_status")
        if status in ("missing_bytes", "downloaded", "thumbnail_only", "failed", "unsupported"):
            item["backup_status"] = status
        for key in ("sha256", "poster_sha256"):
            if isinstance(source.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", source[key]):
                item[key] = source[key]
        for key in ("bytes", "poster_bytes"):
            if type(source.get(key)) is int and source[key] >= 0:
                item[key] = source[key]
        if source.get("format") in ("jpeg", "png", "webp", "gif", "mp4"):
            item["format"] = source["format"]
        result["media"].append(item)
    return result
