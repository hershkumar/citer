"""Turn an arbitrary paper URL (or bare DOI / arXiv ID) into canonical identifiers."""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from urllib.parse import unquote, urlparse

import httpx

from .ids import ARXIV_NEW, ARXIV_OLD, DOI_RE

ARXIV_ID_RE = re.compile(rf"(?P<id>{ARXIV_NEW}|{ARXIV_OLD})(?:v\d+)?")
ARXIV_URL_RE = re.compile(
    rf"arxiv\.org/(?:abs|pdf|html|format|bibtex)/(?P<id>{ARXIV_NEW}|{ARXIV_OLD})(?:v\d+)?",
    re.IGNORECASE,
)

# Path segments publishers append after the DOI in their URLs.
TRAILING_SEGMENTS = {
    "abstract", "full", "fulltext", "pdf", "epdf", "pdfdirect", "meta", "figures",
    "references", "citedby", "supplemental", "suppl", "html", "text", "export",
}

# Hosts whose /articles/<slug> URLs map directly onto a DOI prefix.
SLUG_DOI_PREFIX = {
    "nature.com": "10.1038",
    "www.nature.com": "10.1038",
}

# Silverchair hosts (/<org>/<journal>/article/<volume>/<issue>/<page>/<id>/<title-slug>) have
# no DOI in their URLs and block page fetches with Cloudflare, so they're looked up in Crossref.
SILVERCHAIR_DOI_PREFIX = {
    "pubs.aip.org": "10.1063",
}
SILVERCHAIR_PATH_RE = re.compile(
    r"/[^/]+/[^/]+/article(?:-abstract)?/(?P<volume>[^/]+)/[^/]+/(?P<page>[^/]+)/\d+(?:/(?P<slug>[^/]+))?"
)

# Elsevier URLs (sciencedirect.com/science/article/[abs/]pii/<PII>) carry a PII instead of a
# DOI and block page fetches; Elsevier deposits the PII in Crossref as an alternative ID.
PII_HOSTS = {"www.sciencedirect.com", "sciencedirect.com", "linkinghub.elsevier.com"}
PII_PATH_RE = re.compile(r"/pii/(?P<pii>S?[0-9X]{16})(?:[/?#]|$)", re.IGNORECASE)


@dataclass
class Paper:
    url: str | None = None
    arxiv_id: str | None = None
    doi: str | None = None
    landing_url: str | None = None  # publisher page, if known

    @property
    def host(self) -> str:
        u = self.landing_url or self.url
        return urlparse(u).netloc.lower() if u else ""

    @property
    def doi_prefix(self) -> str:
        """Registrant prefix of the DOI, e.g. "10.1103"."""
        return self.doi.split("/", 1)[0] if self.doi else ""


def clean_doi(doi: str) -> str:
    """Normalize a DOI taken from a URL: unquote, drop page-type suffixes and ".pdf"."""
    doi = unquote(doi).strip().rstrip(".,;)")
    parts = doi.split("/")
    # Drop trailing path segments that are page types rather than part of the DOI.
    while len(parts) > 2 and parts[-1].lower() in TRAILING_SEGMENTS:
        parts.pop()
    doi = "/".join(parts)
    if doi.lower().endswith(".pdf"):
        doi = doi[:-4]
    return doi


def doi_from_url(url: str) -> str | None:
    parsed = urlparse(url)
    m = DOI_RE.search(unquote(parsed.path))
    if m:
        return clean_doi(m.group(0))
    host = parsed.netloc.lower()
    if host in SLUG_DOI_PREFIX:
        m = re.match(r"/articles/([^/?#]+)", parsed.path)
        if m:
            slug = m.group(1).removesuffix(".pdf")
            return f"{SLUG_DOI_PREFIX[host]}/{slug}"
    # Some sites put the DOI in a query parameter (?doi=10.xxx/yyy).
    m = DOI_RE.search(unquote(parsed.query))
    if m:
        return clean_doi(m.group(0))
    return None


def crossref_items(client: httpx.Client, params: dict) -> list[dict]:
    """Items from a Crossref works query, retrying briefly when rate-limited (HTTP 429)."""
    for delay in (1, 2, 4, None):
        resp = client.get("https://api.crossref.org/works", params=params)
        if resp.status_code != 429 or delay is None:
            break
        time.sleep(delay)
    if resp.status_code == 429:
        raise LookupError("Crossref is rate-limiting requests; try again in a few seconds")
    if resp.status_code != 200:
        return []
    return resp.json()["message"]["items"]


def doi_from_pii(url: str, client: httpx.Client) -> str | None:
    """DOI of an Elsevier article URL, found in Crossref by the PII in its path."""
    parsed = urlparse(url)
    m = PII_PATH_RE.search(parsed.path)
    if parsed.netloc.lower() not in PII_HOSTS or not m:
        return None
    items = crossref_items(client, {"filter": f"alternative-id:{m['pii'].upper()}", "rows": 1, "select": "DOI"})
    return items[0]["DOI"] if items else None


def doi_from_crossref(url: str, client: httpx.Client) -> str | None:
    """DOI of a Silverchair article URL, found in Crossref by volume, first page and title slug."""
    parsed = urlparse(url)
    prefix = SILVERCHAIR_DOI_PREFIX.get(parsed.netloc.lower())
    m = SILVERCHAIR_PATH_RE.match(parsed.path)
    if not prefix or not m:
        return None
    slug = unquote(m["slug"] or "").replace("-", " ")
    items = crossref_items(
        client,
        {
            "filter": f"prefix:{prefix}",
            "query.bibliographic": f"{slug} {m['volume']} {m['page']}".strip(),
            "rows": 20,
            "select": "DOI,volume,page,article-number",
        },
    )
    for item in items:
        first_page = item.get("page", "").split("-")[0]
        if item.get("volume") == m["volume"] and m["page"] in (item.get("article-number"), first_page):
            return item["DOI"]
    return None


def doi_from_html(html: str) -> tuple[str | None, str | None]:
    """Return (doi, arxiv_id) from the Highwire/Dublin Core meta tags of a landing page."""
    from bs4 import BeautifulSoup  # only needed for this fallback; slow to import

    soup = BeautifulSoup(html, "html.parser")
    doi = arxiv = None
    for name in ("citation_doi", "dc.identifier", "DC.identifier", "prism.doi", "doi", "DOI"):
        tag = soup.find("meta", attrs={"name": name})
        if tag and tag.get("content"):
            m = DOI_RE.search(tag["content"])
            if m:
                doi = clean_doi(m.group(0))
                break
    tag = soup.find("meta", attrs={"name": "citation_arxiv_id"})
    if tag and tag.get("content"):
        arxiv = tag["content"].strip()
    return doi, arxiv


def resolve(target: str, client: httpx.Client) -> Paper:
    """Identify the paper behind a URL, DOI or arXiv ID (fetching the page only as a last resort)."""
    target = target.strip()

    # Bare identifiers.
    if target.lower().startswith("doi:"):
        return Paper(doi=clean_doi(target[4:]))
    if target.lower().startswith("arxiv:"):
        target = target[6:]
    if DOI_RE.fullmatch(target):
        return Paper(doi=clean_doi(target))
    if m := ARXIV_ID_RE.fullmatch(target):
        return Paper(arxiv_id=m.group("id"))

    if "://" not in target and "." not in target.split("/")[0]:
        raise LookupError("not a URL, DOI or arXiv ID")
    url = target if "://" in target else f"https://{target}"
    paper = Paper(url=url)

    if m := ARXIV_URL_RE.search(url):
        paper.arxiv_id = m.group("id")
        return paper

    host = urlparse(url).netloc.lower()
    if host in ("doi.org", "dx.doi.org", "www.doi.org"):
        paper.doi = clean_doi(urlparse(url).path.lstrip("/"))
        return paper

    paper.landing_url = url
    if doi := doi_from_url(url) or doi_from_pii(url, client) or doi_from_crossref(url, client):
        paper.doi = doi
        return paper

    # Last resort: fetch the page and read its citation meta tags.
    resp = client.get(url)
    paper.landing_url = str(resp.url)
    if "html" in resp.headers.get("content-type", ""):
        paper.doi, paper.arxiv_id = doi_from_html(resp.text)
    if not paper.doi and not paper.arxiv_id:
        paper.doi = doi_from_url(str(resp.url))
    if not paper.doi and not paper.arxiv_id:
        raise LookupError(f"could not find a DOI or arXiv ID for {url}")
    return paper
