import argparse
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("test", "sanitize"))
    kind = parser.parse_args().kind
    pixi = Path("pixi.toml").read_text()
    tasks = re.search(r"^\[tasks\]\n(.*?)(?=^\[|\Z)", pixi, re.M | re.S).group(1)
    declared = set(re.findall(rf"^({kind}-[a-z0-9-]+)\s*=", tasks, re.M))
    workflow = Path(".github/workflows/ci.yml").read_text()
    steps = set(re.findall(rf"^\s*run: pixi run ({kind}-[a-z0-9-]+)\s*$", workflow, re.M))
    aggregate = re.search(rf"^{kind} = \{{ depends-on = \[(.*?)\]\s*\}}", tasks, re.M | re.S).group(1)
    included = set(re.findall(rf'"({kind}-[a-z0-9-]+)"', aggregate))
    required = declared - ({"test-package"} if kind == "test" else set())
    if declared != steps or not required <= included:
        raise SystemExit(
            f"missing CI steps: {sorted(declared - steps)}\n"
            f"extra CI steps: {sorted(steps - declared)}\n"
            f"missing aggregate tasks: {sorted(required - included)}"
        )
    print(f"{len(declared)} default {kind} tasks match CI and aggregate")


if __name__ == "__main__":
    main()
