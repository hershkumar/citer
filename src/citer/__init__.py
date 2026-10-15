"""citer: fetch BibTeX for a paper from the publisher's (or arXiv's) own export endpoint.

Modules:
    resolve    URL / DOI / arXiv ID -> Paper identifiers
    exporters  one function per BibTeX source (arXiv, APS, Springer Nature, Atypon, ...)
    fetch      which exporters to try for a paper, run concurrently
    bib        BibTeX parsing, duplicate detection, appending to .bib files
    cli        the `citer` command
"""
