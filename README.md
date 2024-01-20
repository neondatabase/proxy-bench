# Neon Proxy Benchmark Suite

Neon's Postgres Proxy has 2 major dependencies.
1. Control Plane
2. Postgres

When benchmarking the proxy service, it might be useful to make sure that these are not the bottlenecks. This repo provides mocked implementations of those two services such that the proxy works.

## Setup

```
./tls.sh
docker compose up -d
```

## Run a benchmark

For example:

```sh
for i in $(seq 1 1000);
do
    psql "postgresql://demo:password@ep-database${i}.localtest.me:5432/demo?sslmode=require" -c "select 1;" &
    curl -k "https://ep-database${i}.localtest.me:4443/sql" \
        -H "Neon-Connection-String: postgresql://demo:password@ep-database${i}.localtest.me/demo" \
        --data '{"query":"select 1;","params":[]}' &
done
wait
```

The password will always be `password`. The username/endpoint name can be whatever you like.
