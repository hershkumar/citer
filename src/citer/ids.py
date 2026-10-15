"""Identifier patterns shared by URL resolution and BibTeX duplicate detection."""

import re

# New-style (2301.01234) and old-style (hep-th/9901001, math.AG/0601001) arXiv identifiers.
ARXIV_NEW = r"\d{4}\.\d{4,5}"
ARXIV_OLD = r"[a-zA-Z\-]+(?:\.[A-Z]{2})?/\d{7}"
ARXIV_NEW_RE = re.compile(ARXIV_NEW)
ARXIV_OLD_RE = re.compile(ARXIV_OLD)

DOI_RE = re.compile(r"10\.\d{4,9}/[^\s?#\"'<>]+")
