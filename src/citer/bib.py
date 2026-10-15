"""Minimal BibTeX parsing and duplicate detection (mirrors nvim/lua/citer/bib.lua)."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

SKIP_TYPES = {"comment", "string", "preamble"}
ENTRY_START = re.compile(r"@\s*(\w+)\s*[{(]")
FIELD_NAME = re.compile(r"[\s,]*([\w\-.:]+)\s*=\s*")
ARXIV_NEW = re.compile(r"\d{4}\.\d{4,5}")
ARXIV_OLD = re.compile(r"[a-zA-Z\-]+(?:\.[A-Z]{2})?/\d{7}")


@dataclass
class Entry:
    type: str
    key: str
    fields: dict[str, str]  # name -> raw value, delimiters included
    order: list[tuple[str, str]] = field(default_factory=list)
    raw: str = ""
    line: int = 1


def _balanced(text: str, i: int) -> int:
    """Index just past the brace group starting at text[i] == '{'."""
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return j + 1
    return len(text)


def _read_value(body: str, i: int) -> tuple[str, int]:
    c = body[i : i + 1]
    if c == "{":
        j = _balanced(body, i)
        return body[i:j], j
    if c == '"':
        depth = 0
        for j in range(i + 1, len(body)):
            ch = body[j]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            elif ch == '"' and depth == 0:
                return body[i : j + 1], j + 1
        return body[i:], len(body)
    j = body.find(",", i)
    j = len(body) if j < 0 else j
    return body[i:j].strip(), j


def _parse_fields(body: str) -> list[tuple[str, str]]:
    order, i = [], 0
    while i < len(body):
        m = FIELD_NAME.match(body, i)
        if not m:
            break
        raw, i = _read_value(body, m.end())
        order.append((m.group(1).lower(), raw))
    return order


def parse(text: str) -> list[Entry]:
    entries, pos = [], 0
    while m := ENTRY_START.search(text, pos):
        start, open_ = m.start(), m.end() - 1
        if text[open_] == "{":
            stop = _balanced(text, open_)
        else:
            stop = text.find(")", open_)
            stop = len(text) if stop < 0 else stop + 1
        typ = m.group(1).lower()
        if typ not in SKIP_TYPES:
            body = text[open_ + 1 : stop - 1]
            km = re.match(r"\s*([^,\s]+)\s*,", body)
            if km:
                order = _parse_fields(body[km.end() :])
                entries.append(
                    Entry(
                        type=typ,
                        key=km.group(1),
                        fields=dict(order),
                        order=order,
                        raw=text[start:stop],
                        line=text.count("\n", 0, start) + 1,
                    )
                )
        pos = stop
    return entries


def parse_file(path: Path) -> list[Entry]:
    return parse(path.read_text(encoding="utf-8")) if path.exists() else []


def clean(raw: str | None) -> str:
    if not raw:
        return ""
    v = raw
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        v = v[1:-1]
    v = re.sub(r"\\[a-zA-Z]+", "", v)
    v = re.sub(r"\\.", "", v)
    v = re.sub(r"[{}]", "", v)
    return re.sub(r"\s+", " ", v).strip()


# --- Identity ------------------------------------------------------------------


def doi(e: Entry) -> str | None:
    d = clean(e.fields.get("doi"))
    if not d:
        m = re.search(r"doi\.org/(10\..+)$", clean(e.fields.get("url")))
        d = m.group(1) if m else ""
    d = re.sub(r"^(https?://[^/]*doi\.org/|doi:)", "", d)
    return d.lower() or None


def arxiv(e: Entry) -> str | None:
    f = e.fields
    prefix = clean(f.get("archiveprefix") or f.get("eprinttype")).lower()
    candidates = []
    if "eprint" in f and prefix in ("arxiv", ""):
        candidates.append(clean(f["eprint"]))
    for name in ("url", "journal", "note", "howpublished"):
        v = clean(f.get(name))
        if "arxiv" in v.lower():
            candidates.append(v)
    for c in candidates:
        if m := ARXIV_NEW.search(c) or ARXIV_OLD.search(c):
            return m.group(0)
    return None


def norm_title(e: Entry) -> str | None:
    t = re.sub(r"[^a-z0-9]", "", clean(e.fields.get("title")).lower())
    return t or None


class Index:
    """Lookup tables over existing entries for duplicate checks."""

    def __init__(self, entries: list[Entry] = ()):
        self.doi: dict[str, Entry] = {}
        self.arxiv: dict[str, Entry] = {}
        self.title: dict[str, Entry] = {}
        self.key: dict[str, Entry] = {}
        for e in entries:
            self.add(e)

    def add(self, e: Entry) -> None:
        for table, value in ((self.doi, doi(e)), (self.arxiv, arxiv(e)), (self.title, norm_title(e))):
            if value:
                table.setdefault(value, e)
        self.key.setdefault(e.key, e)

    def find_duplicate(self, e: Entry) -> tuple[Entry, str] | None:
        if (d := doi(e)) and d in self.doi:
            return self.doi[d], "same DOI"
        if (a := arxiv(e)) and a in self.arxiv:
            return self.arxiv[a], "same arXiv ID"
        if (t := norm_title(e)) and t in self.title:
            return self.title[t], "same title"
        return None

    def unique_key(self, key: str) -> str:
        if key not in self.key:
            return key
        for c in "abcdefghijklmnopqrstuvwxyz":
            if key + c not in self.key:
                return key + c
        n = 2
        while f"{key}_{n}" in self.key:
            n += 1
        return f"{key}_{n}"


# --- Writing -------------------------------------------------------------------


def format_entry(e: Entry, key: str | None = None) -> str:
    """Re-emit an entry in a uniform multi-line layout (values kept verbatim)."""
    lines = [f"@{e.type}{{{key or e.key},"]
    for i, (name, raw) in enumerate(e.order):
        lines.append(f"  {name} = {raw}" + ("," if i < len(e.order) - 1 else ""))
    lines.append("}")
    return "\n".join(lines)


def entry_text(e: Entry, key: str) -> str:
    """Text to write: the source's own layout, unless it came as a single line."""
    if "\n" not in e.raw:
        return format_entry(e, key)
    return re.sub(rf"^(@\s*\w+\s*[{{(]\s*){re.escape(e.key)}", lambda m: m.group(1) + key, e.raw, count=1)


def append(path: Path, chunks: list[str]) -> None:
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    lead = ""
    if existing:
        lead = "" if existing.endswith("\n\n") else ("\n" if existing.endswith("\n") else "\n\n")
    with path.open("a", encoding="utf-8") as f:
        f.write(lead + "\n\n".join(chunks) + "\n")
