#!/bin/bash
set -euo pipefail

# Configuration
MAX_DURATION="${MAX_DURATION:-600}"        # 10 minutes in seconds
MAX_LATENCY_MS="${MAX_LATENCY_MS:-200}"    # Maximum allowed latency in milliseconds (p99)
MAX_ERROR_RATE="${MAX_ERROR_RATE:-0.0001}" # Maximum allowed error rate (0.01%)
MAX_RSS_MEMORY="${MAX_RSS_MEMORY:-500}"    # Maximum allowed RSS memory in MB (500MB)

check_metrics() {
    # 1. Check latency (p99)
    local latency=$(curl -s "http://localhost:9090/api/v1/query" \
        --data-urlencode 'query=histogram_quantile(0.99, sum(rate(proxy_compute_connection_latency_seconds_bucket{outcome="success", excluded="client_and_cplane"}[5m]))by (le))' | jq -r '.data.result[0].value[1]')

    # 2. Check error rate
    local error_rate=$(curl -s "http://localhost:9090/api/v1/query" \
        --data-urlencode 'query=sum(rate(proxy_errors_total{type!~"user|clientdisconnect|quota"}[5m])) / sum(rate(proxy_accepted_connections_total[5m]))' | jq -r '.data.result[0].value[1]')

    # 3. Get total client connections
    # Get per-protocol open client connections
    local connections_json=$(curl -s "http://localhost:9090/api/v1/query" \
        --data-urlencode 'query=sum by (protocol) (proxy_opened_client_connections_total - proxy_closed_client_connections_total)')

    open_connections_http=$(echo "$connections_json" | jq -r '.data.result[] | select(.metric.protocol=="http") | .value[1]')
    open_connections_tcp=$(echo "$connections_json" | jq -r '.data.result[] | select(.metric.protocol=="tcp") | .value[1]')

    # 4. Get max memory consumption
    local max_memory=$(curl -s "http://localhost:9090/api/v1/query" \
        --data-urlencode 'query=max(libmetrics_maxrss_kb)' | jq -r '.data.result[0].value[1]')

    # 5. Get jemalloc metrics
    local jemalloc_active=$(curl -s "http://localhost:9090/api/v1/query" \
        --data-urlencode 'query=sum(jemalloc_active_bytes)' | jq -r '.data.result[0].value[1]')
    local jemalloc_allocated=$(curl -s "http://localhost:9090/api/v1/query" \
        --data-urlencode 'query=sum(jemalloc_allocated_bytes)' | jq -r '.data.result[0].value[1]')
    local jemalloc_mapped=$(curl -s "http://localhost:9090/api/v1/query" \
        --data-urlencode 'query=sum(jemalloc_mapped_bytes)' | jq -r '.data.result[0].value[1]')
    local jemalloc_metadata=$(curl -s "http://localhost:9090/api/v1/query" \
        --data-urlencode 'query=sum(jemalloc_metadata_bytes)' | jq -r '.data.result[0].value[1]')
    local jemalloc_resident=$(curl -s "http://localhost:9090/api/v1/query" \
        --data-urlencode 'query=sum(jemalloc_resident_bytes)' | jq -r '.data.result[0].value[1]')

    # Convert latency to milliseconds
    latency=$(echo "$latency * 1000" | bc)

    # Convert bytes to MB for better readability
    jemalloc_active_mb=$(echo "scale=2; $jemalloc_active / 1024 / 1024" | bc)
    jemalloc_allocated_mb=$(echo "scale=2; $jemalloc_allocated / 1024 / 1024" | bc)
    jemalloc_mapped_mb=$(echo "scale=2; $jemalloc_mapped / 1024 / 1024" | bc)
    jemalloc_metadata_mb=$(echo "scale=2; $jemalloc_metadata / 1024 / 1024" | bc)
    jemalloc_resident_mb=$(echo "scale=2; $jemalloc_resident / 1024 / 1024" | bc)

    # Check if metrics exceed thresholds
    if (( $(echo "$latency > $MAX_LATENCY_MS" | bc -l) )); then
        echo "Latency threshold exceeded: ${latency}ms > ${MAX_LATENCY_MS}ms"
        return 1
    fi

    if (( $(echo "$error_rate > $MAX_ERROR_RATE" | bc -l) )); then
        echo "Error rate threshold exceeded: ${error_rate} > ${MAX_ERROR_RATE}"
        return 1
    fi

    if (( $(echo "$max_memory > $MAX_RSS_MEMORY * 1024" | bc -l) )); then
        echo "Max RSS memory threshold exceeded: ${max_memory}KB > $((MAX_RSS_MEMORY * 1024))KB"
        return 1
    fi

    return 0
}

docker compose build --no-cache

# create certs
./tls.sh

echo "Starting services..."
docker compose up -d

echo "Waiting for services to be ready..."
sleep 30

start_time=$(date +%s)

# Main monitoring loop
while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))

    if [ $elapsed -gt $MAX_DURATION ]; then
        echo "Test duration exceeded ${MAX_DURATION} seconds"
        exit 1
    fi

    if ! check_metrics; then
        echo "Metrics check failed"
        exit 1
    fi

    sleep 10
done
