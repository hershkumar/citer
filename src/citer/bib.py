"""Minimal BibTeX parsing, duplicate detection and appending (mirrors lua/citer/bib.lua)."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from .ids import ARXIV_NEW_RE, ARXIV_OLD_RE

SKIP_TYPES = {"comment", "string", "preamble"}
ENTRY_START = re.compile(r"@\s*(\w+)\s*[{(]")
ENTRY_KEY = re.compile(r"\s*([^,\s]+)\s*,")
FIELD_NAME = re.compile(r"[\s,]*([\w\-.:]+)\s*=\s*")
# Characters that matter while looking for a closing delimiter, keyed by that delimiter.
SCAN = {"}": re.compile(r"[{}]"), '"': re.compile(r'[{}"]'), ")": re.compile(r"[{})]")}


@dataclass
class Entry:
    type: str
    key: str
    fields: dict[str, str]  # name -> raw value, delimiters included
    order: list[tuple[str, str]] = field(default_factory=list)
    raw: str = ""
    line: int = 1


# --- Parsing -------------------------------------------------------------------


def _close(text: str, i: int, closer: str) -> int:
    """Index just past the first `closer` at brace depth 0, scanning from `i`."""
    depth = 0
    for m in SCAN[closer].finditer(text, i):
        ch = m.group()
        if ch == closer and depth == 0:
            return m.end()
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
    return len(text)


def _read_value(body: str, i: int) -> tuple[str, int]:
    """Read the field value at `i`; returns (raw value, index after it)."""
    c = body[i : i + 1]
    if c == "{":
        j = _close(body, i + 1, "}")
    elif c == '"':
        j = _close(body, i + 1, '"')
    else:  # bare value: number, month macro, concatenation
        j = body.find(",", i)
        j = len(body) if j < 0 else j
        return body[i:j].strip(), j
    return body[i:j], j


def _parse_fields(body: str) -> list[tuple[str, str]]:
    order, i = [], 0
    while m := FIELD_NAME.match(body, i):
        raw, i = _read_value(body, m.end())
        order.append((m.group(1).lower(), raw))
    return order


def parse(text: str) -> list[Entry]:
    entries, pos = [], 0
    line, counted = 1, 0  # line number at offset `counted`
    while m := ENTRY_START.search(text, pos):
        start, open_ = m.start(), m.end() - 1
        stop = _close(text, open_ + 1, "}" if text[open_] == "{" else ")")
        line += text.count("\n", counted, start)
        counted = start
        typ = m.group(1).lower()
        if typ not in SKIP_TYPES:
            body = text[open_ + 1 : stop - 1]
            if km := ENTRY_KEY.match(body):
                order = _parse_fields(body[km.end() :])
                entries.append(
                    Entry(typ, km.group(1), dict(order), order, text[start:stop], line)
                )
        pos = stop
    return entries


def parse_file(path: Path) -> list[Entry]:
    return parse(path.read_text(encoding="utf-8")) if path.exists() else []


def clean(raw: str | None) -> str:
    """Strip delimiters, braces and LaTeX markup from a raw field value."""
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
        if m := ARXIV_NEW_RE.search(c) or ARXIV_OLD_RE.search(c):
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
        """`key`, or `key` plus a suffix (a..z, then _2, _3, ...) if a different entry has it."""
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
    head = re.compile(rf"^(@\s*\w+\s*[{{(]\s*){re.escape(e.key)}")
    return head.sub(lambda m: m.group(1) + key, e.raw, count=1)


def append(path: Path, chunks: list[str]) -> None:
    """Append entries to `path`, keeping one blank line between entries."""
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    lead = ""
    if existing:
        lead = "" if existing.endswith("\n\n") else ("\n" if existing.endswith("\n") else "\n\n")
    with path.open("a", encoding="utf-8") as f:
        f.write(lead + "\n\n".join(chunks) + "\n")


@dataclass
class Outcome:
    """What happened to one fetched entry: added under `key`, or skipped as a duplicate."""

    added: bool
    key: str
    title: str
    reason: str | None = None  # why it was skipped


class BibFile:
    """A .bib file plus its duplicate index, re-read only when the file changes on disk."""

    def __init__(self, path: Path):
        self.path = path
        self._stamp: tuple[int, int] | None = None
        self._index = Index()

    def _stat(self) -> tuple[int, int] | None:
        try:
            st = self.path.stat()
        except FileNotFoundError:
            return None
        return st.st_mtime_ns, st.st_size

    def index(self) -> Index:
        if (stamp := self._stat()) != self._stamp:
            self._index = Index(parse_file(self.path))
            self._stamp = stamp
        return self._index

    def add(self, texts: list[str]) -> list[Outcome]:
        """Append the entries in `texts`, skipping papers already in the file."""
        index = self.index()
        chunks, outcomes = [], []
        for text in texts:
            for e in parse(text):
                title = clean(e.fields.get("title"))
                if dup := index.find_duplicate(e):
                    existing, why = dup
                    outcomes.append(Outcome(False, existing.key, title, why))
                    continue
                key = index.unique_key(e.key)
                chunks.append(entry_text(e, key))
                e.key = key
                index.add(e)
                outcomes.append(Outcome(True, key, title))
        if chunks:
            append(self.path, chunks)
            self._stamp = self._stat()
        return outcomes
