"""Exercise release checks against isolated manifests."""

import pathlib
import subprocess
import tempfile


CHECK = pathlib.Path(__file__).with_name("check_release_version.sh").resolve()


def check(tag, pixi="0.2.0", recipe="0.2.0"):
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        (root / "pixi.toml").write_text(f'[workspace]\nversion = "{pixi}"\n')
        (root / "conda.recipe").mkdir()
        (root / "conda.recipe/recipe.yaml").write_text(
            f'context:\n  version: "{recipe}"\n'
        )
        result = subprocess.run(
            ["bash", str(CHECK), tag], cwd=root, capture_output=True, text=True
        )
        return result.returncode == 0


assert check("v0.2.0")
assert not check("0.2.0")
assert not check("v00.2.0")
assert not check("v0.2.0-rc1")
assert not check("v0.2.0", pixi="0.1.0")
assert not check("v0.2.0", recipe="0.1.0")
assert check("v0.1.0", pixi="0.1.0", recipe="0.1.0")
print("Release version checks: PASS (7 cases)")
