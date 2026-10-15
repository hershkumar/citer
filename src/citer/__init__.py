"""citer: fetch publisher-provided BibTeX for a paper URL."""

from __future__ import annotations

import sys
from enum import Enum
from pathlib import Path
from typing import Annotated

import httpx
import typer

from . import bib, exporters
from .bib import Index
from .exporters import ExportError
from .resolve import Paper, resolve

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/130.0 Safari/537.36"
)


class Source(str, Enum):
    auto = "auto"
    publisher = "publisher"
    arxiv = "arxiv"
    doi = "doi"
    inspire = "inspire"


def plan(paper: Paper, source: Source) -> list[tuple[str, exporters.Exporter]]:
    """Ordered list of exporters to try for this paper."""
    steps: list[tuple[str, exporters.Exporter]] = []
    pub = exporters.publisher_exporter(paper)

    if source in (Source.auto, Source.publisher):
        if paper.doi:
            if pub:
                steps.append(pub)
            if source is Source.auto:
                steps.append(("doi", exporters.doi))
        if paper.arxiv_id and source is Source.auto:
            steps.append(("arxiv", exporters.arxiv))
    elif source is Source.arxiv and paper.arxiv_id:
        steps.append(("arxiv", exporters.arxiv))
    elif source is Source.doi and paper.doi:
        steps.append(("doi", exporters.doi))
    elif source is Source.inspire:
        steps.append(("inspire", exporters.inspire))
    return steps


def fetch(target: str, client: httpx.Client, source: Source, published: bool) -> tuple[str, str]:
    paper = resolve(target, client)

    # An arXiv link means "use arXiv's export", unless asked for the journal version.
    if paper.arxiv_id and not paper.doi and (published or source in (Source.publisher, Source.doi)):
        paper.doi = exporters.arxiv_published_doi(client, paper.arxiv_id)
        if paper.doi:
            typer.echo(f"  arXiv:{paper.arxiv_id} -> doi:{paper.doi}", err=True)
            if source is Source.auto:
                paper.arxiv_id = None
        elif published:
            typer.echo(f"  arXiv:{paper.arxiv_id} has no journal DOI; using arXiv", err=True)

    steps = plan(paper, source)
    if not steps:
        raise LookupError(f"no {source.value} export available for {target}")

    errors = []
    for name, exporter in steps:
        try:
            return name, exporter(client, paper)
        except (ExportError, httpx.HTTPError) as e:
            errors.append(f"{name}: {e}")
            typer.echo(f"  {name} failed: {e}", err=True)
    raise LookupError("; ".join(errors))


def add_to_bib(path: Path, texts: list[str]) -> list[str]:
    """Append fetched entries to `path`, skipping papers already in it. Returns status lines."""
    index = Index(bib.parse_file(path))
    chunks, msgs = [], []
    for text in texts:
        for e in bib.parse(text):
            if dup := index.find_duplicate(e):
                existing, why = dup
                msgs.append(f"skipped: already in {path.name} as {existing.key} ({why})")
                continue
            key = index.unique_key(e.key)
            chunks.append(bib.entry_text(e, key))
            e.key = key
            index.add(e)
            msgs.append(f"added {key}: {bib.clean(e.fields.get('title'))}")
    if chunks:
        bib.append(path, chunks)
    return msgs


def default_bib() -> Path:
    found = sorted(Path.cwd().glob("*.bib"))
    if len(found) == 1:
        return found[0]
    if found:
        names = ", ".join(f.name for f in found)
        raise typer.BadParameter(f"several .bib files here ({names}); choose one with -o")
    return Path("references.bib")


def interactive(client: httpx.Client, source: Source, published: bool, output: Path) -> None:
    try:
        import readline  # noqa: F401  (line editing and history for input())
    except ImportError:
        pass
    count = len(bib.parse_file(output))
    typer.echo(f"citer -> {output} ({count} entries)", err=True)
    typer.echo("Paste URLs, DOIs or arXiv IDs (several per line is fine). Ctrl-D to quit.", err=True)
    while True:
        try:
            line = input("citer> ").strip()
        except (EOFError, KeyboardInterrupt):
            typer.echo(err=True)
            return
        if line in ("q", "quit", "exit"):
            return
        for target in line.split():
            try:
                name, text = fetch(target, client, source, published)
            except (LookupError, httpx.HTTPError) as e:
                typer.echo(f"error: {target}: {e}", err=True)
                continue
            for msg in add_to_bib(output, [text]):
                typer.echo(f"  {msg} [via {name}]", err=True)


app = typer.Typer(add_completion=False)


@app.command()
def cli(
    targets: Annotated[
        list[str] | None,
        typer.Argument(help="Paper URLs, DOIs, or arXiv IDs. Read from stdin if piped."),
    ] = None,
    source: Annotated[
        Source, typer.Option("--source", "-s", help="Where to get the BibTeX from.")
    ] = Source.auto,
    published: Annotated[
        bool,
        typer.Option("--published", "-p", help="For arXiv links, use the journal version if one exists."),
    ] = False,
    output: Annotated[
        Path | None,
        typer.Option(
            "--output", "-o", help="Append entries to this .bib file, skipping papers already in it."
        ),
    ] = None,
    interactive_: Annotated[
        bool,
        typer.Option(
            "--interactive",
            "-i",
            help="Prompt for papers and add each to the .bib file (default with no arguments).",
        ),
    ] = False,
) -> None:
    """Fetch BibTeX for papers from the publisher's or arXiv's own export endpoint."""
    targets = targets or []
    if not targets and not interactive_ and not sys.stdin.isatty():
        targets = sys.stdin.read().split()
    with httpx.Client(
        headers={"User-Agent": USER_AGENT}, follow_redirects=True, timeout=20
    ) as client:
        if interactive_ or not targets:
            interactive(client, source, published, output or default_bib())
            return

        texts = []
        failed = 0
        for target in targets:
            try:
                name, text = fetch(target, client, source, published)
            except (LookupError, httpx.HTTPError) as e:
                typer.echo(f"error: {target}: {e}", err=True)
                failed += 1
                continue
            typer.echo(f"  {target} [via {name}]", err=True)
            texts.append(text)

    if output:
        for msg in add_to_bib(output, texts):
            typer.echo(f"  {msg}", err=True)
    elif texts:
        typer.echo("\n\n".join(texts) + "\n", nl=False)
    raise typer.Exit(1 if failed else 0)


def main() -> None:
    app()
