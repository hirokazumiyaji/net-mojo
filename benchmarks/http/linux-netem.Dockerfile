FROM ghcr.io/prefix-dev/pixi@sha256:788ae451641666e2d1f79d3dbe35392dfc7e9b394b16a3acb75c347f3badb2ab

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 gcc g++ iproute2 nghttp2-client golang-go procps lsof strace \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
ENTRYPOINT ["/bin/bash"]
