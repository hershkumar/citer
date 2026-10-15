"""Command-line interface: one-shot, piped, and interactive modes."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import httpx

from .bib import BibFile, Outcome
from .fetch import Source, fetch_all, make_client


def err(msg: str = "") -> None:
    print(msg, file=sys.stderr, flush=True)


def describe(outcome: Outcome, path: Path) -> str:
    if outcome.added:
        return f"added {outcome.key}: {outcome.title}"
    return f"skipped: already in {path.name} as {outcome.key} ({outcome.reason})"


def default_bib() -> Path:
    """The only .bib in the current directory, or references.bib if there is none."""
    found = sorted(Path.cwd().glob("*.bib"))
    if len(found) == 1:
        return found[0]
    if found:
        names = ", ".join(f.name for f in found)
        raise SystemExit(f"citer: several .bib files here ({names}); choose one with -o")
    return Path("references.bib")


def interactive(client: httpx.Client, source: Source, published: bool, output: Path) -> None:
    try:
        import readline  # noqa: F401  (line editing and history for input())
    except ImportError:
        pass
    bibfile = BibFile(output)
    err(f"citer -> {output} ({len(bibfile.index().key)} entries)")
    err("Paste URLs, DOIs or arXiv IDs (several per line is fine). Ctrl-D to quit.")
    while True:
        try:
            line = input("citer> ").strip()
        except (EOFError, KeyboardInterrupt):
            err()
            return
        if line in ("q", "quit", "exit"):
            return
        for target, log, result in fetch_all(line.split(), client, source, published):
            for msg in log:
                err(msg)
            if isinstance(result, Exception):
                err(f"error: {target}: {result}")
                continue
            name, text = result
            for outcome in bibfile.add([text]):
                err(f"  {describe(outcome, output)} [via {name}]")


def batch(client: httpx.Client, args: argparse.Namespace, targets: list[str]) -> int:
    """Fetch all targets; print BibTeX to stdout or add it to --output. Returns the exit code."""
    texts, failed = [], 0
    for target, log, result in fetch_all(targets, client, args.source, args.published):
        for msg in log:
            err(msg)
        if isinstance(result, Exception):
            err(f"error: {target}: {result}")
            failed += 1
            continue
        name, text = result
        err(f"  {target} [via {name}]")
        texts.append(text)

    if args.output:
        for outcome in BibFile(args.output).add(texts):
            err(f"  {describe(outcome, args.output)}")
    elif texts:
        sys.stdout.write("\n\n".join(texts) + "\n")
    return 1 if failed else 0


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="citer",
        description="Fetch BibTeX for papers from the publisher's or arXiv's own export endpoint.",
    )
    p.add_argument("targets", nargs="*", help="paper URLs, DOIs, or arXiv IDs (read from stdin if piped)")
    p.add_argument(
        "-s",
        "--source",
        type=Source,
        choices=list(Source),
        default=Source.auto,
        metavar="{" + ",".join(Source) + "}",
        help="where to get the BibTeX from (default: auto)",
    )
    p.add_argument(
        "-p", "--published", action="store_true", help="for arXiv links, use the journal version if one exists"
    )
    p.add_argument(
        "-o", "--output", type=Path, help="append entries to this .bib file, skipping papers already in it"
    )
    p.add_argument(
        "-i",
        "--interactive",
        action="store_true",
        help="prompt for papers and add each to the .bib file (default with no arguments)",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    targets = args.targets
    if not targets and not args.interactive and not sys.stdin.isatty():
        targets = sys.stdin.read().split()
    with make_client() as client:
        if args.interactive or not targets:
            interactive(client, args.source, args.published, args.output or default_bib())
            return
        code = batch(client, args, targets)
    sys.exit(code)
