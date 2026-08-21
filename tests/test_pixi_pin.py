from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_pixi_pins_stable_mojo():
    pixi = (ROOT / "pixi.toml").read_text()
    assert 'mojo = "==1.0.0"' in pixi
    assert "https://conda.modular.com/max" in pixi
    assert "max-nightly" not in pixi


def test_docs_and_uv_do_not_require_nightly_mojo():
    readme = (ROOT / "README.md").read_text()
    pyproject = (ROOT / "pyproject.toml").read_text()
    assert "1.0.0b3" not in readme
    assert "max-nightly" not in readme
    assert "nightly Mojo" not in readme
    assert "1.0.0b3" not in pyproject
    assert "modular-nightly" not in pyproject
    assert "whl.modular.com/nightly" not in pyproject
