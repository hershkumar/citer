import os
import time

import pytest

from citer import exporters
from citer.exporters import ExportError
from citer.fetch import Source, fetch_all, make_client, plan, run_steps
from citer.resolve import Paper


def names(steps):
    return [name for name, _ in steps]


def test_plan_routes_by_publisher():
    aps = Paper(doi="10.1103/PhysRevB.98.045131")
    assert names(plan(aps, Source.auto)) == ["aps", "doi"]
    assert names(plan(aps, Source.publisher)) == ["aps"]
    assert names(plan(Paper(doi="10.1038/nature14539"), Source.auto)) == ["springer", "doi"]
    assert names(plan(Paper(doi="10.1126/science.1217069"), Source.auto)) == ["atypon", "doi"]
    assert names(plan(Paper(doi="10.1016/j.x.2012.1"), Source.auto)) == ["doi"]
    assert names(plan(Paper(arxiv_id="1706.03762"), Source.auto)) == ["arxiv"]
    assert names(plan(Paper(arxiv_id="1706.03762"), Source.doi)) == []
    assert names(plan(Paper(arxiv_id="1706.03762"), Source.inspire)) == ["inspire"]


def test_atypon_uses_doi_host_when_url_is_elsewhere():
    paper = Paper(url="https://doi.org/10.1126/science.1217069", doi="10.1126/science.1217069")
    calls = []

    class Client:
        def get(self, url, **kwargs):
            calls.append(url)
            raise ExportError("stop")

    with pytest.raises(ExportError):
        exporters.atypon(Client(), paper)
    assert calls == ["https://www.science.org/action/downloadCitation"]


def test_run_steps_falls_back_in_order():
    def fail(client, paper):
        raise ExportError("blocked")

    log = []
    steps = [("aps", fail), ("doi", lambda c, p: "@misc{a,}")]
    assert run_steps(steps, None, Paper(), log) == ("doi", "@misc{a,}")
    assert log == ["  aps failed: blocked"]


def test_run_steps_starts_fallback_early_for_unreliable_exporters():
    started = {}

    def slow_fail(client, paper):
        time.sleep(0.2)
        raise ExportError("blocked")

    def fallback(client, paper):
        started["at"] = time.monotonic()
        return "@misc{a,}"

    t0 = time.monotonic()
    name, _ = run_steps([("atypon", slow_fail), ("doi", fallback)], None, Paper(), [])
    assert name == "doi" and started["at"] - t0 < 0.1


def test_run_steps_reports_all_errors():
    def fail(client, paper):
        raise ExportError("nope")

    with pytest.raises(LookupError, match="aps: nope; doi: nope"):
        run_steps([("aps", fail), ("doi", fail)], None, Paper(), [])


network = pytest.mark.skipif(not os.environ.get("CITER_NETWORK"), reason="set CITER_NETWORK=1 to hit live endpoints")


@network
@pytest.mark.parametrize(
    "target, via",
    [
        ("https://arxiv.org/abs/1706.03762", "arxiv"),
        ("https://journals.aps.org/prxquantum/abstract/10.1103/PRXQuantum.4.027001", "aps"),
        ("10.1103/PhysRevB.98.045131", "aps"),
        ("https://www.nature.com/articles/s42254-023-00599-8", "springer"),
        ("https://www.science.org/doi/10.1126/science.1217069", "doi"),
        (
            "https://pubs.aip.org/aip/jmp/article/48/10/102111/379272/Bounds-for-the-adiabatic-approximation-with",
            "doi",
        ),
        ("https://www.sciencedirect.com/science/article/pii/S0146641022000497", "doi"),
    ],
)
def test_live_endpoints(target, via):
    with make_client() as client:
        [(_, _, result)] = list(fetch_all([target], client, Source.auto, False))
    assert not isinstance(result, Exception), result
    name, text = result
    assert name == via and text.lstrip().startswith("@")
