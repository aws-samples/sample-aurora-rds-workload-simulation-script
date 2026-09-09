#!/bin/bash
#
# simulate_contentious_load_with_striped_inventory.sh
#
# Simulates a high-concurrency write load against a small item_inventory
# range using sysbench and place_order_optimized_and_reduced_contention.lua,
# which spreads each item's inventory count across multiple "stripe" rows
# (see copy_item_inventory_to_striped.sh) and uses FOR UPDATE SKIP LOCKED to
# reduce row lock contention compared to simulate_contentious_load.sh.
#
# place_order_optimized_and_reduced_contention.lua retries its inventory
# update (bounded) when the SKIP LOCKED CTE finds no available stripe row,
# and reports per-thread retry/failure/processed-item counts to a CSV file
# (see INVENTORY_STATS_LOG below), which this script aggregates into totals
# printed alongside the sysbench log.
#
# Requires item_inventory_striped and item_inventory_striping_config to
# already exist (run copy_item_inventory_to_striped.sh first).
#
# Example:
#   ./simulate_contentious_load_with_striped_inventory.sh -h "$PGHOST" -w "$PGPASSWORD" -t 600

set -euo pipefail

cd "$(dirname "$0")"

readonly LUA_SCRIPT="place_order_optimized_and_reduced_contention.lua"

# Defaults tuned to maximize row lock contention:
# a small inventory_scale concentrates writes on very few item_inventory
# rows, and a single item per order maximizes update contention on those rows.
readonly default_username="test_user"
readonly default_database="testdb"
readonly default_port="5432"
readonly default_threads=512
readonly default_run_time=600
readonly default_inventory_scale=10
readonly default_user_scale=10000
readonly default_items_per_order=1
readonly default_output_dir="`pwd`/output"

usage() {
    cat <<EOF
Usage: $0 -h <host> -w <password> [options]

Simulates a high-contention write workload for the order placement schema
using sysbench and ${LUA_SCRIPT} against the striped item_inventory tables.

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
  -I <inventory_scale>   Rows in item_inventory to concentrate writes on [default: ${default_inventory_scale}]
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

run_timestamp="$(date +%Y%m%d%H%M%S)"
log_file="${output_dir}/place_orders_contentious_load_striped_${run_timestamp}.log"

# INVENTORY_STATS_LOG: read by place_order_optimized_and_reduced_contention.lua
# (if present) to append one "thread_id,total_retries,total_failures,total_items_processed"
# line per thread in thread_done(). The header is written here so the file
# is well-formed even if no thread ever writes to it.
export INVENTORY_STATS_LOG="${output_dir}/inventory_stats_${run_timestamp}.csv"
echo "thread_id,total_retries,total_failures,total_items_processed" > "$INVENTORY_STATS_LOG"

echo "$(date '+%H:%M:%S'): Starting contentious load (striped inventory) simulation against ${host}:${port}/${database} for ${run_time}s with ${threads} threads."
echo "$(date '+%H:%M:%S'): Logging sysbench output to ${log_file}"

if PGPASSWORD="$password" sysbench --db-driver=pgsql \
    --pgsql-host="$host" --pgsql-port="$port" --pgsql-user="$username" \
    --pgsql-db="$database" --pgsql-password="$password" \
    --threads="$threads" --events=0 --time="$run_time" --forced-shutdown=60 \
    --inventory_scale="$inventory_scale" --user_scale="$user_scale" \
    --items_per_order="$items_per_order" \
    "$LUA_SCRIPT" run >>"$log_file" 2>&1; then
    echo "$(date '+%H:%M:%S'): Contentious load (striped inventory) simulation completed successfully."
else
    status=$?
    echo "$(date '+%H:%M:%S'): Contentious load (striped inventory) simulation failed with exit code ${status}. See ${log_file} for details." >&2
    exit "$status"
fi

# Aggregate per-thread inventory retry/failure/processed-item counts, and
# append the summary to the same log file sysbench wrote to above.
if [[ -f "$INVENTORY_STATS_LOG" ]] && [[ $(wc -l < "$INVENTORY_STATS_LOG") -gt 1 ]]; then
    read -r total_retries total_failures total_items_processed < <(
        awk -F',' 'NR>1 { retries+=$2; failures+=$3; processed+=$4 }
                   END { print retries+0, failures+0, processed+0 }' \
            "$INVENTORY_STATS_LOG"
    )

    {
        echo ""
        echo "Inventory update retry summary (from ${INVENTORY_STATS_LOG}):"
        echo "    total retries:                       ${total_retries}"
        echo "    total failures (after max retries):  ${total_failures}"
        echo "    total items processed:               ${total_items_processed}"
    } | tee -a "$log_file"
fi
