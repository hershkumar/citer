"""Fetch BibTeX from the source's own export endpoint (what the "Export citation" button calls)."""

from __future__ import annotations

import re
from typing import Callable
from urllib.parse import quote, urlparse

import httpx

from .resolve import Paper


class ExportError(Exception):
    pass


def _looks_like_bibtex(text: str) -> bool:
    return bool(re.match(r"\s*@\w+\s*\{", text))


def _get_bibtex(client: httpx.Client, url: str, **kwargs) -> str:
    resp = client.get(url, **kwargs)
    if resp.status_code != 200:
        raise ExportError(f"HTTP {resp.status_code} from {url}")
    if not _looks_like_bibtex(resp.text):
        hint = " (blocked by bot protection)" if "Just a moment" in resp.text else ""
        raise ExportError(f"response from {url} is not BibTeX{hint}")
    return resp.text.strip()


# --- arXiv -----------------------------------------------------------------


def arxiv(client: httpx.Client, paper: Paper) -> str:
    return _get_bibtex(client, f"https://arxiv.org/bibtex/{paper.arxiv_id}")


def arxiv_published_doi(client: httpx.Client, arxiv_id: str) -> str | None:
    """The journal DOI that the authors attached to an arXiv record, if any."""
    resp = client.get("https://export.arxiv.org/api/query", params={"id_list": arxiv_id})
    m = re.search(r"<arxiv:doi[^>]*>([^<]+)</arxiv:doi>", resp.text)
    return m.group(1).strip() if m else None


# --- APS -------------------------------------------------------------------


def _aps_journal(client: httpx.Client, paper: Paper) -> str:
    """APS export URLs need the journal code (prl, prb, prxquantum, ...)."""
    for u in (paper.landing_url, paper.url):
        if u and "journals.aps.org" in u:
            return urlparse(u).path.strip("/").split("/")[0]
    # Follow doi.org -> link.aps.org -> journals.aps.org/<journal>/abstract/<doi>.
    resp = client.head(f"https://doi.org/{paper.doi}")
    path = urlparse(str(resp.url)).path
    if "journals.aps.org" not in str(resp.url):
        raise ExportError(f"could not determine APS journal for {paper.doi}")
    return path.strip("/").split("/")[0]


def aps(client: httpx.Client, paper: Paper) -> str:
    journal = _aps_journal(client, paper)
    return _get_bibtex(
        client,
        f"https://journals.aps.org/{journal}/export/{paper.doi}",
        params={"type": "bibtex", "download": "true"},
    )


# --- Springer Nature (nature.com, link.springer.com, BMC, ...) -------------


def springer(client: httpx.Client, paper: Paper) -> str:
    return _get_bibtex(
        client,
        f"https://citation-needed.springer.com/v2/references/{paper.doi}",
        params={"format": "bibtex", "flavour": "citation"},
    )


# --- Atypon platform (ACS, Wiley, Science, SIAM, T&F, PNAS, ...) -----------


def atypon(client: httpx.Client, paper: Paper) -> str:
    host = paper.host or ATYPON_DOI_HOSTS.get(paper.doi.split("/")[0], "")
    if not host:
        raise ExportError("no Atypon host known for this DOI")
    return _get_bibtex(
        client,
        f"https://{host}/action/downloadCitation",
        params={"doi": paper.doi, "format": "bibtex", "include": "cit"},
    )


# --- INSPIRE-HEP (physics) --------------------------------------------------


def inspire(client: httpx.Client, paper: Paper) -> str:
    if paper.arxiv_id:
        url = f"https://inspirehep.net/api/arxiv/{paper.arxiv_id}"
    else:
        url = f"https://inspirehep.net/api/doi/{quote(paper.doi, safe='/')}"
    return _get_bibtex(client, url, params={"format": "bibtex"})


# --- DOI content negotiation (Crossref / DataCite), the universal fallback --


def doi(client: httpx.Client, paper: Paper) -> str:
    return _get_bibtex(
        client,
        f"https://doi.org/{paper.doi}",
        headers={"Accept": "application/x-bibtex; charset=utf-8"},
    )


# --- Routing ---------------------------------------------------------------

Exporter = Callable[[httpx.Client, Paper], str]

APS_PREFIX = "10.1103"
SPRINGER_PREFIXES = {"10.1038", "10.1007", "10.1186", "10.1140", "10.1057"}
SPRINGER_HOSTS = ("nature.com", "springer.com", "biomedcentral.com", "springeropen.com")
ATYPON_HOSTS = (
    "pubs.acs.org", "onlinelibrary.wiley.com", "www.science.org", "epubs.siam.org",
    "www.tandfonline.com", "www.pnas.org", "journals.sagepub.com", "ascelibrary.org",
    "journals.ametsoc.org", "www.annualreviews.org", "pubs.rsna.org", "www.liebertpub.com",
)
# Where to send Atypon requests when we only have a DOI, keyed by DOI prefix.
ATYPON_DOI_HOSTS = {
    "10.1021": "pubs.acs.org",
    "10.1002": "onlinelibrary.wiley.com",
    "10.1111": "onlinelibrary.wiley.com",
    "10.1126": "www.science.org",
    "10.1137": "epubs.siam.org",
    "10.1080": "www.tandfonline.com",
    "10.1073": "www.pnas.org",
    "10.1177": "journals.sagepub.com",
    "10.1146": "www.annualreviews.org",
}


def publisher_exporter(paper: Paper) -> tuple[str, Exporter] | None:
    """Pick the publisher-native exporter for a DOI, if we know one."""
    if not paper.doi:
        return None
    prefix = paper.doi.split("/")[0]
    host = paper.host
    if prefix == APS_PREFIX or host.endswith("aps.org"):
        return "aps", aps
    if prefix in SPRINGER_PREFIXES or host.endswith(SPRINGER_HOSTS):
        return "springer", springer
    if host in ATYPON_HOSTS or prefix in ATYPON_DOI_HOSTS:
        return "atypon", atypon
    return None
