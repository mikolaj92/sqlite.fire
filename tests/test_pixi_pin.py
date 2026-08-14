from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_pixi_pins_stable_mojo():
    pixi = (ROOT / "pixi.toml").read_text()
    assert 'mojo = "==1.0.0"' in pixi
    assert "https://conda.modular.com/max" in pixi
    assert "max-nightly" not in pixi
