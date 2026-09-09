#!/bin/bash
#
# simulate_avg_load.sh
#
# Simulates a steady, low-contention write load against the order placement
# schema using sysbench and place_order_writes_only_optimized.lua. Intended
# to represent typical/average traffic (as opposed to simulate_contentious_load.sh,
# which deliberately drives up row lock contention).
#
# Example:
#   ./simulate_avg_load.sh -h "$PGHOST" -w "$PGPASSWORD" -t 3300

set -euo pipefail

cd "$(dirname "$0")"

readonly LUA_SCRIPT="place_order_writes_only_optimized.lua"

# Defaults tuned for a steady, low-contention write workload:
# a large inventory_scale spreads writes across many rows and minimizes
# row lock contention on item_inventory.
readonly default_username="test_user"
readonly default_database="testdb"
readonly default_port="5432"
readonly default_threads=128
readonly default_run_time=900
readonly default_inventory_scale=10000000
readonly default_user_scale=10000
readonly default_items_per_order=5
readonly default_output_dir="./output"

usage() {
    cat <<EOF
Usage: $0 -h <host> -w <password> [options]

Simulates an average, low-contention write workload for the order placement
schema using sysbench and ${LUA_SCRIPT}.

Required:
  -h <host>              Primary database endpoint
  -w <password>          Database password. Prefer setting PGPASSWORD in the
                         environment instead: -w is visible to other users on
                         the same host via /proc/<pid>/cmdline and may end up
                         in shell history.

Optional:
  -u <username>          Database username [default: ${default_username}]
  -d <database>          Database name [default: ${default_database}]
  -p <port>              Database port [default: ${default_port}]
  -n <threads>           Sysbench threads [default: ${default_threads}]
  -t <run_time>          Run time in seconds [default: ${default_run_time}]
  -I <inventory_scale>   Rows in item_inventory to spread writes across [default: ${default_inventory_scale}]
  -U <user_scale>        Number of users to select from when placing orders [default: ${default_user_scale}]
  -X <items_per_order>   Items per order [default: ${default_items_per_order}]
  -o <output_dir>        Directory to write logs to [default: ${default_output_dir}]
EOF
    exit 1
}

username="$default_username"
database="$default_database"
port="$default_port"
threads="$default_threads"
run_time="$default_run_time"
inventory_scale="$default_inventory_scale"
user_scale="$default_user_scale"
items_per_order="$default_items_per_order"
output_dir="$default_output_dir"
host=""
password="${PGPASSWORD:-}"

while getopts ":h:w:u:d:p:n:t:I:U:X:o:" opt; do
    case ${opt} in
        h) host=$OPTARG ;;
        w) password=$OPTARG ;;
        u) username=$OPTARG ;;
        d) database=$OPTARG ;;
        p) port=$OPTARG ;;
        n) threads=$OPTARG ;;
        t) run_time=$OPTARG ;;
        I) inventory_scale=$OPTARG ;;
        U) user_scale=$OPTARG ;;
        X) items_per_order=$OPTARG ;;
        o) output_dir=$OPTARG ;;
        \?)
            echo "Error: Invalid option -$OPTARG" >&2
            usage
            ;;
        :)
            echo "Error: Option -$OPTARG requires an argument." >&2
            usage
            ;;
    esac
done

if [[ -z "$host" || -z "$password" ]]; then
    echo "Error: -h <host> and -w <password> (or PGPASSWORD env var) are required." >&2
    usage
fi

if [[ ! -f "$LUA_SCRIPT" ]]; then
    echo "Error: ${LUA_SCRIPT} not found in $(pwd)." >&2
    exit 1
fi

if ! command -v sysbench >/dev/null 2>&1; then
    echo "Error: sysbench is not installed or not on PATH." >&2
    exit 1
fi

if ! mkdir -p "$output_dir"; then
    echo "Error: Unable to create output directory ${output_dir}." >&2
    exit 1
fi

log_file="${output_dir}/place_orders_avg_load_$(date +%Y%m%d%H%M%S).log"

echo "$(date '+%H:%M:%S'): Starting average load simulation against ${host}:${port}/${database} for ${run_time}s with ${threads} threads."
echo "$(date '+%H:%M:%S'): Logging sysbench output to ${log_file}"

if PGPASSWORD="$password" sysbench --db-driver=pgsql \
    --pgsql-host="$host" --pgsql-port="$port" --pgsql-user="$username" \
    --pgsql-db="$database" --pgsql-password="$password" \
    --threads="$threads" --events=0 --time="$run_time" --forced-shutdown=60 \
    --inventory_scale="$inventory_scale" --user_scale="$user_scale" \
    --items_per_order="$items_per_order" \
    "$LUA_SCRIPT" run >>"$log_file" 2>&1; then
    echo "$(date '+%H:%M:%S'): Average load simulation completed successfully."
else
    status=$?
    echo "$(date '+%H:%M:%S'): Average load simulation failed with exit code ${status}. See ${log_file} for details." >&2
    exit "$status"
fi
