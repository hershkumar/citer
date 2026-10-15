"""Decide which exporters to try for a target and run them, concurrently where it helps."""

from __future__ import annotations

from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from enum import StrEnum

import httpx

from . import exporters
from .exporters import ExportError, Exporter
from .resolve import Paper, resolve

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/130.0 Safari/537.36"
)
MAX_PARALLEL = 8

Step = tuple[str, Exporter]


class Source(StrEnum):
    auto = "auto"
    publisher = "publisher"
    arxiv = "arxiv"
    doi = "doi"
    inspire = "inspire"


def make_client() -> httpx.Client:
    return httpx.Client(
        headers={"User-Agent": USER_AGENT},
        follow_redirects=True,
        timeout=20,
        limits=httpx.Limits(max_connections=MAX_PARALLEL * 2),
    )


def plan(paper: Paper, source: Source) -> list[Step]:
    """Ordered list of exporters to try for this paper."""
    if source is Source.arxiv:
        return [("arxiv", exporters.arxiv)] if paper.arxiv_id else []
    if source is Source.doi:
        return [("doi", exporters.doi)] if paper.doi else []
    if source is Source.inspire:
        return [("inspire", exporters.inspire)]

    steps: list[Step] = []
    if paper.doi:
        if pub := exporters.publisher_exporter(paper):
            steps.append(pub)
        if source is Source.auto:
            steps.append(("doi", exporters.doi))
    if paper.arxiv_id and source is Source.auto:
        steps.append(("arxiv", exporters.arxiv))
    return steps


def run_steps(steps: list[Step], client: httpx.Client, paper: Paper, log: list[str]) -> tuple[str, str]:
    """Return (exporter name, BibTeX) from the first step that succeeds, in plan order."""
    errors = []

    def attempt(name: str, exporter: Exporter) -> str | None:
        try:
            return exporter(client, paper)
        except (ExportError, httpx.HTTPError) as e:
            errors.append(f"{name}: {e}")
            log.append(f"  {name} failed: {e}")
            return None

    if steps[0][0] in exporters.UNRELIABLE and len(steps) > 1:
        # Start the fallbacks now rather than after the first step is (usually) refused.
        with ThreadPoolExecutor(len(steps)) as pool:
            futures = [(name, pool.submit(attempt, name, fn)) for name, fn in steps]
            for name, future in futures:
                if (text := future.result()) is not None:
                    return name, text
    else:
        for name, fn in steps:
            if (text := attempt(name, fn)) is not None:
                return name, text
    raise LookupError("; ".join(errors))


def fetch(
    target: str, client: httpx.Client, source: Source, published: bool, log: list[str]
) -> tuple[str, str]:
    """Fetch BibTeX for one URL, DOI or arXiv ID. Progress notes are appended to `log`."""
    paper = resolve(target, client)

    # An arXiv link means "use arXiv's export", unless asked for the journal version.
    if paper.arxiv_id and not paper.doi and (published or source in (Source.publisher, Source.doi)):
        paper.doi = exporters.arxiv_published_doi(client, paper.arxiv_id)
        if paper.doi:
            log.append(f"  arXiv:{paper.arxiv_id} -> doi:{paper.doi}")
            if source is Source.auto:
                paper.arxiv_id = None
        elif published:
            log.append(f"  arXiv:{paper.arxiv_id} has no journal DOI; using arXiv")

    steps = plan(paper, source)
    if not steps:
        raise LookupError(f"no {source.value} export available for {target}")
    return run_steps(steps, client, paper, log)


Result = tuple[str, list[str], tuple[str, str] | Exception]


def fetch_all(targets: list[str], client: httpx.Client, source: Source, published: bool) -> Iterator[Result]:
    """Fetch targets concurrently; yields (target, log, (name, bibtex) or error) in input order."""

    def one(target: str) -> Result:
        log: list[str] = []
        try:
            return target, log, fetch(target, client, source, published, log)
        except (LookupError, httpx.HTTPError) as e:
            return target, log, e

    if len(targets) == 1:
        yield one(targets[0])
        return
    with ThreadPoolExecutor(min(MAX_PARALLEL, len(targets))) as pool:
        yield from pool.map(one, targets)
