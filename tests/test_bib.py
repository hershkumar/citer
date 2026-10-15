from pathlib import Path

from citer import bib

ARXIV = """@misc{vaswani2023attentionneed,
      title={Attention Is All You Need},
      author={Ashish Vaswani and Noam Shazeer},
      year={2023},
      eprint={1706.03762},
      archivePrefix={arXiv},
      primaryClass={cs.CL},
}"""

APS = """@article{PhysRevB.98.045131,
  title = {Tunable topological semimetal states with ultraflat nodal rings in strained {YN}},
  author = {Huang, Huaqing and Jiang, Wei},
  journal = {Phys. Rev. B},
  year = {2018},
  doi = {10.1103/PhysRevB.98.045131},
}"""

SPRINGER = """@Article{LeCun2015,
author="LeCun, Yann
and Bengio, Yoshua",
title="Deep {learning}",
journal="Nature",
year="2015",
doi="10.1038/nature14539"
}"""

# Single-line output from doi.org content negotiation.
CROSSREF = (
    " @article{Jordan_2012, title={Quantum Algorithms for Quantum Field Theories}, volume={336},"
    " DOI={10.1126/science.1217069}, author={Jordan, Stephen P.}, year={2012}, month=June }"
)


def test_parse_entry_styles():
    entries = bib.parse("\n\n".join([ARXIV, APS, SPRINGER, CROSSREF]))
    assert [e.key for e in entries] == [
        "vaswani2023attentionneed",
        "PhysRevB.98.045131",
        "LeCun2015",
        "Jordan_2012",
    ]
    assert [e.line for e in entries] == [1, 10, 18, 27]
    lecun = entries[2]
    assert lecun.type == "article"
    assert lecun.fields["title"] == '"Deep {learning}"'
    assert entries[3].fields["month"] == "June"  # bare macro value


def test_parse_skips_comments_and_paren_entries():
    text = '@comment{ignore me}\n@string{foo = "bar"}\n@misc(key1, title = {A (b) c})\n'
    [e] = bib.parse(text)
    assert e.key == "key1" and bib.clean(e.fields["title"]) == "A (b) c"


def test_clean():
    assert bib.clean('"Deep {learning}"') == "Deep learning"
    assert bib.clean(r"{K{\"u}bra   and\n {\'E}mile}") == "Kubra and Emile"
    assert bib.clean(None) == ""


def test_identity():
    arxiv, aps, springer, crossref = bib.parse("\n".join([ARXIV, APS, SPRINGER, CROSSREF]))
    assert bib.arxiv(arxiv) == "1706.03762"
    assert bib.doi(arxiv) is None
    assert bib.doi(aps) == "10.1103/physrevb.98.045131"
    assert bib.doi(crossref) == "10.1126/science.1217069"
    assert bib.norm_title(springer) == "deeplearning"


def test_find_duplicate_by_doi_arxiv_and_title():
    index = bib.Index(bib.parse("\n".join([ARXIV, APS])))
    [same_doi] = bib.parse(APS.replace("PhysRevB.98.045131,", "other,", 1))
    assert index.find_duplicate(same_doi)[1] == "same DOI"
    [same_arxiv] = bib.parse("@misc{x, title={Different}, eprint={1706.03762}}")
    assert index.find_duplicate(same_arxiv)[1] == "same arXiv ID"
    [same_title] = bib.parse("@article{y, title={Attention is all you need!}}")
    assert index.find_duplicate(same_title)[1] == "same title"
    [new] = bib.parse("@article{z, title={Something else}}")
    assert index.find_duplicate(new) is None


def test_unique_key():
    index = bib.Index(bib.parse("@misc{k, title={a}}\n@misc{ka, title={b}}"))
    assert index.unique_key("fresh") == "fresh"
    assert index.unique_key("k") == "kb"


def test_entry_text_keeps_layout_or_reformats_single_line():
    [aps] = bib.parse(APS)
    assert bib.entry_text(aps, "NewKey") == APS.replace("PhysRevB.98.045131,", "NewKey,", 1)
    [crossref] = bib.parse(CROSSREF)
    text = bib.entry_text(crossref, "Jordan_2012")
    assert text.splitlines()[0] == "@article{Jordan_2012,"
    assert "  doi = {10.1126/science.1217069}," in text
    assert text.endswith("  month = June\n}")


def test_bibfile_add_skips_duplicates(tmp_path: Path):
    path = tmp_path / "refs.bib"
    path.write_text(ARXIV + "\n")
    bibfile = bib.BibFile(path)

    outcomes = bibfile.add([APS, SPRINGER, APS])
    assert [(o.added, o.key) for o in outcomes] == [
        (True, "PhysRevB.98.045131"),
        (True, "LeCun2015"),
        (False, "PhysRevB.98.045131"),
    ]
    assert outcomes[2].reason == "same DOI"

    # The in-memory index tracks what was written, and the file has one blank line between entries.
    assert not bibfile.add([SPRINGER])[0].added
    text = path.read_text()
    assert text.count("\n\n@") == 2 and text.endswith("}\n")
    assert [e.key for e in bib.parse(text)] == [
        "vaswani2023attentionneed",
        "PhysRevB.98.045131",
        "LeCun2015",
    ]


def test_bibfile_rereads_after_external_change(tmp_path: Path):
    path = tmp_path / "refs.bib"
    bibfile = bib.BibFile(path)
    assert bibfile.index().key == {}
    path.write_text(APS)
    assert "PhysRevB.98.045131" in bibfile.index().key
