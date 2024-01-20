# Neon Proxy Benchmark Suite

Neon's Postgres Proxy has 2 major dependencies.
1. Control Plane
2. Postgres

When benchmarking the proxy service, it might be useful to make sure that these are not the bottlenecks. This repo provides mocked implementations of those two services such that the proxy works.

## Run

```sh
# create TLS certificates
./tls.sh
# Run neon proxy, haproxy, cplane, postgres, and load test
docker compose up -d
```
