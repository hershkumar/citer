import pytest

from citer.resolve import clean_doi, doi_from_crossref, doi_from_html, doi_from_pii, doi_from_url, resolve


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


class FakeCrossref:
    """Answers a Crossref works query with a fixed item list, recording the request."""

    def __init__(self, items):
        self.items, self.params = items, None

    def get(self, url, params=None, **kwargs):
        assert url == "https://api.crossref.org/works"
        self.params = params
        items = self.items

        class Response:
            status_code = 200

            def json(self):
                return {"message": {"items": items}}

        return Response()


AIP_URL = "https://pubs.aip.org/aip/jmp/article/48/10/102111/379272/Bounds-for-the-adiabatic-approximation-with"


def test_aip_doi_from_crossref_matches_volume_and_page():
    client = FakeCrossref(
        [
            {"DOI": "10.1063/1.2757170", "volume": "127", "article-number": "094103"},
            {"DOI": "10.1063/1.2798382", "volume": "48", "article-number": "102111"},
        ]
    )
    assert resolve(AIP_URL, client).doi == "10.1063/1.2798382"
    assert client.params["filter"] == "prefix:10.1063"
    assert client.params["query.bibliographic"] == "Bounds for the adiabatic approximation with 48 102111"


def test_aip_doi_from_crossref_rejects_mismatches():
    client = FakeCrossref([{"DOI": "10.1063/1.2757170", "volume": "127", "page": "102111-102120"}])
    assert doi_from_crossref(AIP_URL, client) is None
    assert doi_from_crossref("https://example.org/aip/jmp/article/48/10/102111/379272/x", NoNetwork()) is None


@pytest.mark.parametrize(
    "url",
    [
        "https://www.sciencedirect.com/science/article/pii/S0146641022000497",
        "https://www.sciencedirect.com/science/article/abs/pii/S0146641022000497?via%3Dihub",
        "https://www.sciencedirect.com/science/article/pii/S0146641022000497/pdfft?isDTMRedir=true",
        "https://linkinghub.elsevier.com/retrieve/pii/s0146641022000497",
    ],
)
def test_elsevier_doi_from_pii(url):
    client = FakeCrossref([{"DOI": "10.1016/j.ppnp.2022.103991"}])
    assert resolve(url, client).doi == "10.1016/j.ppnp.2022.103991"
    assert client.params["filter"] == "alternative-id:S0146641022000497"


def test_elsevier_pii_needs_known_host():
    assert doi_from_pii("https://example.org/pii/S0146641022000497", NoNetwork()) is None
    assert doi_from_pii("https://www.sciencedirect.com/journal/progress-in-particle-and-nuclear-physics", NoNetwork()) is None


def test_crossref_rate_limit_is_reported(monkeypatch):
    monkeypatch.setattr("citer.resolve.time.sleep", lambda s: None)

    class RateLimited:
        status_code = 429

    class Client:
        def get(self, *args, **kwargs):
            return RateLimited()

    with pytest.raises(LookupError, match="rate-limiting"):
        doi_from_pii("https://www.sciencedirect.com/science/article/pii/S0146641022000497", Client())
