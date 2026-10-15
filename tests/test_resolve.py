import pytest

from citer.resolve import clean_doi, doi_from_html, doi_from_url, resolve


class NoNetwork:
    """Stands in for httpx.Client in cases that must be resolved from the URL alone."""

    def get(self, *args, **kwargs):
        raise AssertionError("unexpected network request")


@pytest.mark.parametrize(
    "target, arxiv_id, doi",
    [
        ("1706.03762", "1706.03762", None),
        ("arXiv:1706.03762v5", "1706.03762", None),
        ("hep-th/9711200", "hep-th/9711200", None),
        ("https://arxiv.org/abs/hep-th/9711200v3", "hep-th/9711200", None),
        ("https://arxiv.org/pdf/1602.03837v1", "1602.03837", None),
        ("10.1103/PhysRevB.98.045131", None, "10.1103/PhysRevB.98.045131"),
        ("doi:10.1038/nature14539", None, "10.1038/nature14539"),
        ("https://doi.org/10.1016/j.physletb.2012.08.020", None, "10.1016/j.physletb.2012.08.020"),
        (
            "https://journals.aps.org/prxquantum/abstract/10.1103/PRXQuantum.4.027001",
            None,
            "10.1103/PRXQuantum.4.027001",
        ),
        ("https://www.science.org/doi/10.1126/science.1217069", None, "10.1126/science.1217069"),
        ("https://www.nature.com/articles/s42254-023-00599-8", None, "10.1038/s42254-023-00599-8"),
        ("nature.com/articles/nature14539.pdf", None, "10.1038/nature14539"),
        (
            "https://iopscience.iop.org/article/10.1088/1742-6596/1524/1/012118/pdf",
            None,
            "10.1088/1742-6596/1524/1/012118",
        ),
        (
            "https://link.springer.com/content/pdf/10.1007/s11259-005-3081-7.pdf",
            None,
            "10.1007/s11259-005-3081-7",
        ),
    ],
)
def test_resolve_without_network(target, arxiv_id, doi):
    paper = resolve(target, NoNetwork())
    assert (paper.arxiv_id, paper.doi) == (arxiv_id, doi)


def test_resolve_rejects_garbage():
    with pytest.raises(LookupError, match="not a URL"):
        resolve("bogus", NoNetwork())


def test_clean_doi():
    assert clean_doi("10.1002%2Fanie.201506001/full") == "10.1002/anie.201506001"
    assert clean_doi("10.1103/PhysRevLett.116.061102.") == "10.1103/PhysRevLett.116.061102"


def test_doi_from_url_query():
    assert doi_from_url("https://example.org/view?doi=10.1137/141000671") == "10.1137/141000671"
    assert doi_from_url("https://example.org/paper/123") is None


def test_doi_from_html_meta_tags():
    html = '<meta name="citation_doi" content="doi:10.1038/nature14539"><meta name="citation_arxiv_id" content="1234.5678">'
    assert doi_from_html(html) == ("10.1038/nature14539", "1234.5678")
