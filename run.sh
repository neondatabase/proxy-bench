#!/bin/bash
set -euo pipefail

# Configuration
MAX_DURATION="${MAX_DURATION:-600}"                 # 10 minutes in seconds
MAX_LATENCY_MS="${MAX_LATENCY_MS:-200}"             # Maximum allowed latency in milliseconds (p99)
MAX_ERROR_RATE="${MAX_ERROR_RATE:-0.0001}"          # Maximum allowed error rate (0.01%)
MAX_JEMALLOC_MEMORY="${MAX_JEMALLOC_MEMORY:-512}"  # Maximum allowed jemalloc memory in MB (512MB)

# Bare metal configuration
BARE_METAL=false
ENABLE_GRAFANA=true
POSTGRES_MOCK_PORT=5432

CPLANE_MOCK_PORT=3010
PROXY_PORT=5433
PROXY_HTTP_PORT=8080
PROXY_WSS_PORT=443
PROMETHEUS_PORT=9090
GRAFANA_PORT=3000

# Path to neon proxy binary (can be overridden by environment variable)
NEON_PROXY_PATH="${NEON_PROXY_PATH:-proxy}"

# Environment variables for load testing
PG_CONNECTION_RATE="${PG_CONNECTION_RATE:-5}"
PG_CONNECTING_MAX="${PG_CONNECTING_MAX:-10}"
PG_CONNECTION_MAX="${PG_CONNECTION_MAX:-20}"
HTTP_CONNECTION_RATE="${HTTP_CONNECTION_RATE:-5}"
HTTP_CONNECTION_MAX="${HTTP_CONNECTION_MAX:-5}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --bare-metal)
            BARE_METAL=true
            shift
            ;;
        --no-grafana)
            ENABLE_GRAFANA=false
            shift
            ;;
        --help)
            echo "Usage: $0 [--bare-metal] [--grafana] [--help]"
            echo "  --bare-metal: Run without Docker containers"
            echo "  --grafana: Enable Grafana in bare metal mode (optional)"
            echo "  --help: Show this help message"
            echo ""
            echo "Environment variables for bare metal mode:"
            echo "  NEON_PROXY_PATH: Path to the neon proxy binary (default: 'proxy')"
            echo "                   You can set this to the full path of the proxy binary"
            echo "                   Example: NEON_PROXY_PATH=/path/to/neon/target/release/proxy"
            echo ""
            echo "Required tools for bare metal mode:"
            echo "  - prometheus: Install from https://prometheus.io/download/"
            echo "  - grafana server: Install from https://grafana.com/grafana/download (only if --grafana is used)"
            echo "  - neon proxy binary: Build from https://github.com/neondatabase/neon"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate flag combinations
if [ "$ENABLE_GRAFANA" = true ] && [ "$BARE_METAL" = false ]; then
    echo "Error: --no-grafana flag can only be used with --bare-metal"
    exit 1
fi

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

    if (( $(echo "jemalloc_active_mb > $MAX_JEMALLOC_MEMORY" | bc -l) )); then
        echo "Jemalloc active memory threshold exceeded: ${jemalloc_active_mb}MB > ${MAX_JEMALLOC_MEMORY}MB"
        return 1
    fi

    return 0
}

# Function to build Rust binaries
build_binaries() {
    echo "Building Rust binaries..."
    cargo build --release
    echo "Binaries built successfully"
}

start_bare_metal_services() {
    echo "Starting bare metal services..."

    # Increase file descriptor limits to prevent "Too many open files" errors
    echo "Current ulimit -n: $(ulimit -n)"

    # Create logs directory
    mkdir -p logs

    # Array to store postgres-bench PIDs
    declare -a POSTGRES_BENCH_PIDS

    # Start postgres-mock (it listens on port 5432 - hardcoded in source)
    echo "Starting postgres-mock on port 5432..."
    RUST_LOG=info ./target/release/postgres-mock > logs/postgres-mock.log 2>&1 &
    POSTGRES_MOCK_PID=$!
    echo "postgres-mock started with PID $POSTGRES_MOCK_PID"

    echo "Starting cplane-mock on port $CPLANE_MOCK_PORT..."
    PROXY_COMPUTE_ADDR="localhost:5432" RUST_LOG=info ./target/release/cplane-mock > logs/cplane-mock.log 2>&1 &
    CPLANE_MOCK_PID=$!
    echo "cplane-mock started with PID $CPLANE_MOCK_PID"

    sleep 5

    echo "Starting neon proxy binary at $NEON_PROXY_PATH..."

    if ! command -v "$NEON_PROXY_PATH" &> /dev/null; then
        echo "Error: Neon proxy binary not found at '$NEON_PROXY_PATH'"
        echo "Please install the neon proxy binary or set NEON_PROXY_PATH to the correct path"
        echo "You can build it from the Neon repository: https://github.com/neondatabase/neon"
        echo "Example: cargo build --release --bin proxy"
        exit 1
    fi

    RUST_LOG=info \
    "$NEON_PROXY_PATH" \
        --auth-backend cplane-v1 \
        --auth-endpoint "http://localhost:$CPLANE_MOCK_PORT/proxy/api/v1" \
        -c "target/proxy.crt" \
        -k "target/proxy.key" \
        --proxy "0.0.0.0:$PROXY_PORT" \
        --http "0.0.0.0:$PROXY_HTTP_PORT" \
        --wss "0.0.0.0:$PROXY_WSS_PORT" \
        --project-info-cache "size=100000,ttl=60m,max_roles=10,gc_interval=60m" \
        --wake-compute-cache "size=100000,ttl=60m" > logs/proxy.log 2>&1 &

    PROXY_PID=$!
    echo "Neon proxy started with PID $PROXY_PID"

    # Create a temporary prometheus config for bare metal
    cat > target/prometheus-bare-metal.yml << EOF
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 15s
scrape_configs:
- job_name: prometheus
  honor_timestamps: true
  scrape_interval: 15s
  scrape_timeout: 10s
  metrics_path: /metrics
  scheme: http
  static_configs:
  - targets:
    - localhost:$PROXY_HTTP_PORT
EOF

    # Start Prometheus
    echo "Starting Prometheus on port $PROMETHEUS_PORT..."
    if command -v prometheus &> /dev/null; then
        prometheus --config.file=target/prometheus-bare-metal.yml \
                   --storage.tsdb.path=target/prometheus-data \
                   --web.listen-address=:$PROMETHEUS_PORT > logs/prometheus.log 2>&1 &
        PROMETHEUS_PID=$!
        echo "Prometheus started with PID $PROMETHEUS_PID"
    else
        echo "Prometheus not found in PATH. Please install Prometheus or use Docker mode."
        echo "You can download it from: https://prometheus.io/download/"
        exit 1
    fi

    sleep 10

    if [ "$ENABLE_GRAFANA" = true ]; then
        # Create Grafana datasource configuration for bare metal
        mkdir -p target/grafana-provisioning/datasources
        cat > target/grafana-provisioning/datasources/datasource.yml << EOF
apiVersion: 1

datasources:
- name: Prometheus
  type: prometheus
  url: http://localhost:$PROMETHEUS_PORT
  isDefault: true
  access: proxy
  editable: true
EOF

        echo "Starting Grafana on port $GRAFANA_PORT..."

        if command -v grafana &> /dev/null; then
            GRAFANA_CMD="grafana server"
        elif command -v grafana-server &> /dev/null; then
            GRAFANA_CMD="grafana-server"
        else
            echo "Grafana not found in PATH. Skipping Grafana startup."
            echo "You can install Grafana from: https://grafana.com/grafana/download"
            GRAFANA_PID=""
            return
        fi

        # Create minimal Grafana config that works without homepath
        mkdir -p target/grafana-data
        cat > target/grafana.ini << EOF
[server]
http_port = $GRAFANA_PORT

[security]
admin_user = admin
admin_password = grafana

[paths]
data = $(pwd)/target/grafana-data
logs = $(pwd)/logs
plugins = $(pwd)/target/grafana-data/plugins
provisioning = $(pwd)/target/grafana-provisioning

[analytics]
reporting_enabled = false
check_for_updates = false

[users]
allow_sign_up = false

[database]
type = sqlite3
path = $(pwd)/target/grafana-data/grafana.db
EOF

        # Start Grafana
        GRAFANA_HOME=""
        if [ -d "/opt/homebrew/share/grafana" ]; then
            GRAFANA_HOME="/opt/homebrew/share/grafana"
        elif [ -d "/usr/local/share/grafana" ]; then
            GRAFANA_HOME="/usr/local/share/grafana"
        elif [ -d "/usr/share/grafana" ]; then
            GRAFANA_HOME="/usr/share/grafana"
        fi

        if [ -n "$GRAFANA_HOME" ]; then
            $GRAFANA_CMD --config=target/grafana.ini --homepath="$GRAFANA_HOME" > logs/grafana.log 2>&1 &
        else
            $GRAFANA_CMD --config=target/grafana.ini > logs/grafana.log 2>&1 &
        fi
        GRAFANA_PID=$!
        echo "Grafana started with PID $GRAFANA_PID"
        echo "Grafana UI available at: http://localhost:$GRAFANA_PORT (admin/grafana)"
    else
        echo "Grafana disabled. Use --grafana flag to enable."
        GRAFANA_PID=""
    fi

    # Start load
    echo "Starting postgres-bench load generators..."
    for i in {1..4}; do
        PG_HOST=neon PG_ADDR="0.0.0.0:$PROXY_PORT" \
        PG_CONNECTION_RATE=$PG_CONNECTION_RATE \
        PG_CONNECTING_MAX=$PG_CONNECTING_MAX \
        PG_CONNECTION_MAX=$PG_CONNECTION_MAX \
        RUST_LOG=info ./target/release/postgres-bench > logs/postgres-bench-$i.log 2>&1 &
        POSTGRES_BENCH_PIDS[$i]=$!
        echo "postgres-bench $i started with PID ${POSTGRES_BENCH_PIDS[$i]}"
    done

    echo "Starting http-bench load generator..."
    PG_HOST=neon PG_ADDR="localhost:$PROXY_WSS_PORT" \
    PG_CONNECTION_RATE=$HTTP_CONNECTION_RATE \
    PG_CONNECTION_MAX=$HTTP_CONNECTION_MAX \
    RUST_LOG=info ./target/release/http-bench > logs/http-bench.log 2>&1 &
    HTTP_BENCH_PID=$!
    echo "http-bench started with PID $HTTP_BENCH_PID"

    # Store PIDs for cleanup
    echo "Storing PIDs for cleanup..."
    mkdir -p target  # Ensure target directory exists
    echo "$POSTGRES_MOCK_PID" > target/postgres-mock.pid
    echo "$CPLANE_MOCK_PID" > target/cplane-mock.pid
    echo "$PROMETHEUS_PID" > target/prometheus.pid
    if [ -n "$GRAFANA_PID" ]; then
        echo "$GRAFANA_PID" > target/grafana.pid
        echo "Stored Grafana PID: $GRAFANA_PID"
    fi
    echo "$HTTP_BENCH_PID" > target/http-bench.pid
    echo "$PROXY_PID" > target/proxy.pid
    for i in {1..4}; do
        echo "${POSTGRES_BENCH_PIDS[$i]}" > target/postgres-bench-$i.pid
        echo "Stored postgres-bench-$i PID: ${POSTGRES_BENCH_PIDS[$i]}"
    done
    echo "All PIDs stored in target/*.pid files"
}

stop_bare_metal_services() {
    echo "Stopping bare metal services..."

    # First, try graceful shutdown with SIGTERM
    echo "Sending SIGTERM to all processes..."
    for pid_file in target/*.pid; do
        if [ -f "$pid_file" ]; then
            PID=$(cat "$pid_file")
            if kill -0 "$PID" 2>/dev/null; then
                echo "Stopping process $PID from $pid_file gracefully"
                kill -TERM "$PID" 2>/dev/null || true
            fi
        fi
    done

    # Give processes time to shut down gracefully (5 seconds)
    echo "Waiting 5 seconds for graceful shutdown..."
    sleep 5

    # Check which processes are still running and force kill them
    echo "Force killing any remaining processes..."
    for pid_file in target/*.pid; do
        if [ -f "$pid_file" ]; then
            PID=$(cat "$pid_file")
            if kill -0 "$PID" 2>/dev/null; then
                echo "Force killing process $PID from $pid_file"
                kill -KILL "$PID" 2>/dev/null || true
            fi
            rm -f "$pid_file"
        fi
    done

    # Clean up any remaining processes with graceful then force approach
    echo "Cleaning up any remaining processes..."
    pkill -TERM -f postgres-mock 2>/dev/null || true
    pkill -TERM -f cplane-mock 2>/dev/null || true
    pkill -TERM -f prometheus 2>/dev/null || true
    pkill -TERM -f "grafana server" 2>/dev/null || true
    pkill -TERM -f postgres-bench 2>/dev/null || true
    pkill -TERM -f http-bench 2>/dev/null || true
    pkill -TERM -f "$NEON_PROXY_PATH" 2>/dev/null || true

    # Wait a bit more
    sleep 2

    # Force kill any stubborn processes
    pkill -KILL -f postgres-mock 2>/dev/null || true
    pkill -KILL -f cplane-mock 2>/dev/null || true
    pkill -KILL -f prometheus 2>/dev/null || true
    pkill -KILL -f "grafana server" 2>/dev/null || true
    pkill -KILL -f postgres-bench 2>/dev/null || true
    pkill -KILL -f http-bench 2>/dev/null || true
    pkill -KILL -f "$NEON_PROXY_PATH" 2>/dev/null || true

    echo "All services stopped"
}

# Trap to ensure cleanup on exit
cleanup() {
    echo "=== CLEANUP TRIGGERED ==="
    echo "Cleanup reason: $1"
    if [ "$BARE_METAL" = true ]; then
        stop_bare_metal_services
    else
        docker compose down
    fi
    echo "=== CLEANUP COMPLETE ==="
}

# Set up traps for different exit conditions
trap 'cleanup "EXIT"' EXIT
trap 'cleanup "INT (Ctrl+C)"' INT
trap 'cleanup "TERM"' TERM

# Check for existing script instances to prevent conflicts
SCRIPT_NAME=$(basename "$0")
# Use a more robust way to count running instances
if pgrep -f "$SCRIPT_NAME" > /dev/null 2>&1; then
    RUNNING_INSTANCES=$(pgrep -f "$SCRIPT_NAME" | grep -v $$ | wc -l 2>/dev/null || echo "0")
    # Remove any leading/trailing whitespace
    RUNNING_INSTANCES=$(echo "$RUNNING_INSTANCES" | tr -d ' ')
    echo "Debug: Found pgrep matches, RUNNING_INSTANCES='$RUNNING_INSTANCES'"
else
    RUNNING_INSTANCES=0
    echo "Debug: No pgrep matches found, RUNNING_INSTANCES=0"
fi

if [ "$RUNNING_INSTANCES" -gt 0 ]; then
    echo "Warning: Found $RUNNING_INSTANCES other instances of $SCRIPT_NAME running"
    echo "This might cause port conflicts and resource issues."
    echo "Consider stopping other instances first."

    # Check if we're running interactively
    if [ -t 0 ]; then
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo "Running non-interactively, continuing anyway..."
    fi
fi

if [ "$BARE_METAL" = true ]; then
    echo "Running in bare metal mode..."
    echo "Using neon proxy binary at: $NEON_PROXY_PATH"
    echo "Services will be available at:"
    echo "  - Prometheus: http://localhost:$PROMETHEUS_PORT"
    if [ "$ENABLE_GRAFANA" = true ]; then
        echo "  - Grafana: http://localhost:$GRAFANA_PORT (admin/grafana)"
    fi

    build_binaries
    ./tls.sh
    start_bare_metal_services

    echo "Waiting for all services to be ready..."
    sleep 30
else
    echo "Running in Docker mode..."
    docker compose build --no-cache

    # create certs
    ./tls.sh

    echo "Starting services..."
    docker compose up -d

    echo "Waiting for services to be ready..."
    sleep 30
fi

echo "Starting main loop"
start_time=$(date +%s)

# Main monitoring loop
while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))

    if [ $elapsed -gt $MAX_DURATION ]; then
        echo "Test duration exceeded ${MAX_DURATION} seconds"
        break
    fi

    if ! check_metrics; then
        echo "Metrics check failed"
        exit 1
    fi

    sleep 10
done
