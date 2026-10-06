# Isolated Linux RTT and packet loss

`linux_netem.py` applies kernel packet delay/loss to loopback in a dedicated
Docker network namespace. It affects real TCP and UDP packets, including TCP
retransmission; it does not delete application bytes. The host network is not
modified. Setup needs network access; disconnect the container before trials.

Build the tool image and create a container. Choose CPU IDs available to the
Docker VM; use separate CPUs for the server and loader.

```bash
docker build -f benchmarks/http/linux-netem.Dockerfile \
  -t net-mojo-http-netem benchmarks/http
docker create --name net-mojo-http-measure --cpuset-cpus 0,1,2 \
  --memory 2g --cap-drop ALL --cap-add NET_ADMIN \
  --security-opt no-new-privileges net-mojo-http-netem -c 'sleep infinity'
docker start net-mojo-http-measure
git archive HEAD | docker exec -i net-mojo-http-measure \
  tar --no-same-owner -C /work -xf -
docker exec net-mojo-http-measure bash -c '
  cd /work
  pixi install --frozen -e tls-http2 -e tls-http3
  pixi run -e tls-http2 tls-build
  pixi run -e tls-http2 hpack-test
  pixi run -e tls-http3 quic-build
  GOTOOLCHAIN=go1.26.4 go -C benchmarks/http_go build -o /work/build/http_go .
  pixi run -e tls-http2 bash -c "PATH=/usr/bin:/bin:\$PATH mojo build \
    --Werror -Xlinker -ldl -I . benchmarks/http2_tls_server.mojo -o build/http2_server"
  pixi run -e tls-http3 bash -c "PATH=/usr/bin:/bin:\$PATH mojo build \
    --Werror -Xlinker -ldl -I . benchmarks/http3_server.mojo -o build/http3_server"
'
docker network disconnect bridge net-mojo-http-measure
docker exec net-mojo-http-measure python3 /work/tests/test_linux_netem.py
```

Run a workload with `--delay-ms 10 --loss-percent 1` for nominal 20ms RTT
and 1% packet loss **in each direction**. A 0/0 run provides the corresponding
unshaped condition. The integration test independently measures UDP round-trip
delay and checks that a nonzero loss setting actually increments kernel drops.
Use a fresh JSON output path for each run.

```bash
docker exec net-mojo-http-measure bash -c '
  cd /work
  python3 benchmarks/http/linux_netem.py --delay-ms 10 --loss-percent 1 \
    --output build/bench/netem/h2.json -- bash -c '\''
      taskset -c 0 build/http2_server > build/h2-server.log 2>&1 &
      server_pid=$!
      trap "kill $server_pid; wait $server_pid" EXIT
      sleep 1
      taskset -c 1,2 h2load --alpn-list=h2 -D 30 --warm-up-time=10 -c 16 -m 10 -t 2 \
        https://127.0.0.1:18443/fixed
    '\''
'
docker cp net-mojo-http-measure:/work/build/bench/netem ./netem-results
docker rm -f net-mojo-http-measure
```

The wrapper preserves workload failure status, stops its process group on
interruption, and removes only its own loopback qdisc. It refuses an existing
qdisc, a non-Docker host, or any active interface other than loopback. A Docker
`none` network can include inactive kernel tunnel interfaces; these carry no
trial traffic. Do not use host networking.

Evidence includes the command, kernel/architecture, per-direction settings,
configured qdisc, post-workload packet/drop counters and post-cleanup qdisc.
Record source revision, tool versions, cipher, actual negotiated protocol,
successful/failed requests, CPU/RSS/fds, and server/loader affinity separately.
Loss is stochastic; distinguish configured percentage from observed drops.
VM measurements are Linux guest measurements, not bare-metal results.
Use the full 10s warmup / 30s measurement / at least five repetitions for
performance comparisons; a short smoke check does not satisfy that procedure.
