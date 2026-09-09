#!/bin/bash
#
# simulate_sporadic_workload.sh
#
# Simulates a sporadic write-only order placement workload against
# PostgreSQL/Aurora PostgreSQL: mostly average load, with occasional
# random bursts of peak load (thread count ramped up before jumping to
# peak, then ramped back down). Uses sysbench and
# place_order_writes_only_optimized.lua.
#
# Example:
#   ./simulate_sporadic_workload.sh -h "$PGHOST" -w "$PGPASSWORD" -d testdb -u test_user \
#     -I 1000000 -U 100000 -X 5 \
#     -N 4 -t 1800 -m 8 -M 256 -T 900 -P 10 -c 600 -C 7200 -r 180

set -euo pipefail

cd "$(dirname "$0")"

readonly LUA_SCRIPT="place_order_writes_only_optimized.lua"

# ---- Defaults --------------------------------------------------------------

default_username="test_user"
default_database="testdb"
default_port="5432"

default_avg_load_threads=16
default_avg_load_run_time=900
default_cool_off_period=900

default_peak_load_min_threads=8
default_peak_load_max_threads=256
default_peak_load_run_time=300
default_peak_load_probability=10
default_peak_load_rerun_cool_off=3600

default_rampup_strategy="exponential"
default_rampup_run_time=90

default_inventory_scale=10000000
default_user_scale=10000
default_items_per_order=5

default_output_dir="./output"

# Allowed ranges for sanity-checking inputs.
avg_load_threads_min_limit=1
avg_load_threads_max_limit=1024
avg_load_run_time_min_limit=10
avg_load_run_time_max_limit=86400

peak_load_min_threads_lower_limit=1
peak_load_min_threads_upper_limit=1024
peak_load_max_threads_lower_limit=1
peak_load_max_threads_upper_limit=2048

peak_load_run_time_min_limit=10
peak_load_run_time_max_limit=86400

cool_off_period_min_limit=5
cool_off_period_max_limit=86400

peak_load_rerun_cool_off_min_limit=10
peak_load_rerun_cool_off_max_limit=604800

peak_load_probability_min_limit=0
peak_load_probability_max_limit=100

rampup_run_time_min_limit=10
rampup_run_time_max_limit=3600

rampup_strategy_valid_values="exponential,linear"

exponential_thread_set="1 2 4 8 16 24 32 40 48 64 80 96 128 160 192 224 256 320 384 448 512 640 768 896 1024 1280 1536 1792 2048"
linear_thread_set="1 5 10 15 20 30 40 50 60 75 100 125 150 175 200 225 250 300 400 500 600 700 800 900 1000 1200 1400 1600 1800 2000"

# ---- Usage ------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 -h <host> -w <password> [options]

Simulates a sporadic write-only order placement workload: average load most
of the time, with occasional randomly-triggered bursts of peak load.

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
  -I <inventory_scale>   Rows in item_inventory to select from [default: ${default_inventory_scale}]
  -U <user_scale>        Number of users to select from when placing orders [default: ${default_user_scale}]
  -X <items_per_order>   Items per order [default: ${default_items_per_order}]
  -O <lua_options>       Additional options to pass to ${LUA_SCRIPT}, e.g. "--skip_trx:true"
  -N <threads>           Sysbench threads for average load [default: ${default_avg_load_threads}]
  -t <run_time>          Average load run time in seconds [default: ${default_avg_load_run_time}]
  -c <cool_off>          Cool off period between cycles, in seconds [default: ${default_cool_off_period}]
  -m <min_threads>       Lower bound for peak load thread count [default: ${default_peak_load_min_threads}]
  -M <max_threads>       Upper bound for peak load thread count [default: ${default_peak_load_max_threads}]
  -T <run_time>          Peak load run time in seconds [default: ${default_peak_load_run_time}]
  -P <probability>       Probability (0-100) of triggering peak load each cycle [default: ${default_peak_load_probability}]
  -C <cool_off>          Minimum gap between two peak load bursts, in seconds [default: ${default_peak_load_rerun_cool_off}]
  -R <strategy>          Thread rampup strategy: exponential|linear [default: ${default_rampup_strategy}]
  -r <run_time>          Time spent at each rampup step, in seconds [default: ${default_rampup_run_time}]
  -o <output_dir>        Directory to write logs and summary CSV to [default: ${default_output_dir}]
EOF
    exit 1
}

# ---- Helpers ----------------------------------------------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

is_value_in_list() {
    local valid_csv=$1
    local check_string=$2
    local description=$3
    local token

    IFS=',' read -ra valid_values <<< "$valid_csv"
    for token in "${valid_values[@]}"; do
        if [[ "$token" == "$check_string" ]]; then
            return 0
        fi
    done

    die "${description} value '${check_string}' is not valid. Valid values are: ${valid_csv}"
}

require_int_in_range() {
    local value=$1
    local min=$2
    local max=$3
    local description=$4

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        die "${description} must be a positive integer, got '${value}'."
    fi

    if (( value < min || value > max )); then
        die "${description} must be between ${min} and ${max}, got '${value}'."
    fi
}

# Run one sysbench invocation of the order placement workload.
run_sysbench() {
    local threads=$1
    local run_time=$2
    local log_file="${output_dir}/sysbench-${threads}threads-$(date +%Y%m%d%H%M%S).log"

    log "Running sysbench with ${threads} threads for ${run_time}s (log: ${log_file})"

    if PGPASSWORD="$password" sysbench --db-driver=pgsql --pgsql-host="$host" \
        --pgsql-user="$username" --pgsql-db="$database" --pgsql-port="$port" \
        --pgsql-password="$password" --threads="$threads" --events=0 \
        --time="$run_time" --forced-shutdown=60 \
        --inventory_scale="$inventory_scale" --user_scale="$user_scale" \
        --items_per_order="$items_per_order" "${lua_script_opt_args[@]}" \
        "$LUA_SCRIPT" run >"$log_file" 2>&1; then
        append_summary "$log_file" "$threads" "$run_time"
        return 0
    else
        local status=$?
        log "sysbench run with ${threads} threads failed with exit code ${status}. See ${log_file} for details." >&2
        return "$status"
    fi
}

# Extract key metrics from a sysbench log and append them as a CSV row.
append_summary() {
    local log_file=$1
    local threads=$2
    local run_time=$3

    local transactions min_lat max_lat avg_lat p95_lat tps qps

    transactions=$(grep -m1 "transactions:" "$log_file" | grep -oE '[0-9]+\.[0-9]+ per sec' | head -1)
    tps=${transactions:-"NA"}
    qps=$(grep -m1 "queries:" "$log_file" | grep -oE '[0-9]+\.[0-9]+ per sec' | head -1)
    qps=${qps:-"NA"}
    min_lat=$(grep -m1 "min:" "$log_file" | awk '{print $2}')
    max_lat=$(grep -m1 "max:" "$log_file" | awk '{print $2}')
    avg_lat=$(grep -m1 "avg:" "$log_file" | awk '{print $2}')
    p95_lat=$(grep -m1 "95th percentile:" "$log_file" | awk '{print $3}')

    echo "${threads},${run_time},${min_lat:-NA},${max_lat:-NA},${avg_lat:-NA},${p95_lat:-NA},${tps},${qps}" >> "$summary_file"
}

get_random_number() {
    local min=$1
    local max=$2
    seq "$min" "$max" | shuf -n 1
}

get_random_thread_count() {
    local min_threads=$1
    local max_threads=$2
    local thread_set=$3
    local valid_threads=()
    local thread_count

    for thread_count in $thread_set; do
        if (( thread_count >= min_threads && thread_count <= max_threads )); then
            valid_threads+=("$thread_count")
        fi
    done

    if [ ${#valid_threads[@]} -eq 0 ]; then
        die "No valid thread counts found between ${min_threads} and ${max_threads}."
    fi

    local last_index random_index
    last_index=$(( ${#valid_threads[@]} - 1 ))
    random_index=$(get_random_number 0 "$last_index")
    echo "${valid_threads[$random_index]}"
}

# Decide whether this cycle should run peak or average load, respecting the
# cool-off period between peak load bursts.
determine_load_type() {
    local timestamp_file="/tmp/simulate_sporadic_workload_last_peak_load"
    local current_time last_peak_load_time time_elapsed random_num

    current_time=$(date +%s)
    last_peak_load_time=0
    if [ -f "$timestamp_file" ]; then
        last_peak_load_time=$(cat "$timestamp_file")
    fi
    time_elapsed=$(( current_time - last_peak_load_time ))

    if (( time_elapsed < peak_load_rerun_cool_off )); then
        log "Last peak load ran ${time_elapsed}s ago; must wait ${peak_load_rerun_cool_off}s between peak bursts. Defaulting to AVG_LOAD."
        echo "AVG_LOAD"
        return 0
    fi

    random_num=$(od -An -N4 -tu4 < /dev/urandom)
    if (( random_num % 100 < peak_load_probability )); then
        echo "$current_time" > "$timestamp_file"
        echo "PEAK_LOAD"
    else
        echo "AVG_LOAD"
    fi
}

run_avg_load() {
    log "Running average load with ${avg_load_threads} threads for ${avg_load_run_time}s"
    run_sysbench "$avg_load_threads" "$avg_load_run_time"
}

run_peak_load() {
    local target_threads t
    target_threads=$(get_random_thread_count "$peak_load_min_threads" "$peak_load_max_threads" "$thread_set")

    log "Ramping up threads towards peak load target of ${target_threads}"
    for t in $thread_set; do
        if (( t < peak_load_min_threads )); then
            continue
        fi
        if (( t > target_threads )); then
            break
        fi
        run_sysbench "$t" "$rampup_run_time" || return 1
    done

    log "Running peak load with ${target_threads} threads for ${peak_load_run_time}s"
    run_sysbench "$target_threads" "$peak_load_run_time"
}

run_workload_cycle() {
    local load_type
    load_type=$(determine_load_type)
    log "Load type for this cycle: ${load_type}"

    case "$load_type" in
        PEAK_LOAD)
            run_peak_load
            ;;
        AVG_LOAD)
            run_avg_load
            ;;
        *)
            log "Unknown load type: ${load_type}" >&2
            return 1
            ;;
    esac
}

cleanup_between_runs() {
    log "Running cleanup: TRUNCATE orders/order_items and VACUUM item_inventory."

    local vacuum_commands=(
        "VACUUM FULL FREEZE ANALYZE item_inventory"
        "VACUUM FREEZE ANALYZE orders"
        "VACUUM FREEZE ANALYZE order_items"
    )
    local cleanup_commands=(
        "TRUNCATE TABLE orders RESTART IDENTITY"
        "TRUNCATE TABLE order_items RESTART IDENTITY"
    )
    local cmd

    for cmd in "${vacuum_commands[@]}"; do
        PGPASSWORD="$password" psql -h "$host" -p "$port" -U "$username" -d "$database" -c "$cmd" \
            || log "WARNING: cleanup command failed: ${cmd}"
    done

    for cmd in "${cleanup_commands[@]}"; do
        PGPASSWORD="$password" psql -h "$host" -p "$port" -U "$username" -d "$database" -c "$cmd" \
            || log "WARNING: cleanup command failed: ${cmd}"
    done
}

# ---- Argument parsing --------------------------------------------------------

username="$default_username"
database="$default_database"
port="$default_port"
lua_script_opt=""

inventory_scale="$default_inventory_scale"
user_scale="$default_user_scale"
items_per_order="$default_items_per_order"

avg_load_threads="$default_avg_load_threads"
avg_load_run_time="$default_avg_load_run_time"
cool_off_period="$default_cool_off_period"

peak_load_min_threads="$default_peak_load_min_threads"
peak_load_max_threads="$default_peak_load_max_threads"
peak_load_run_time="$default_peak_load_run_time"
peak_load_probability="$default_peak_load_probability"
peak_load_rerun_cool_off="$default_peak_load_rerun_cool_off"

rampup_strategy="$default_rampup_strategy"
rampup_run_time="$default_rampup_run_time"

output_dir="$default_output_dir"
host=""
password="${PGPASSWORD:-}"

while getopts ":h:w:u:d:p:I:U:X:O:N:t:c:m:M:T:P:C:R:r:o:" opt; do
    case ${opt} in
        h) host=$OPTARG ;;
        w) password=$OPTARG ;;
        u) username=$OPTARG ;;
        d) database=$OPTARG ;;
        p) port=$OPTARG ;;
        I) inventory_scale=$OPTARG ;;
        U) user_scale=$OPTARG ;;
        X) items_per_order=$OPTARG ;;
        O) lua_script_opt=$OPTARG ;;
        N) avg_load_threads=$OPTARG ;;
        t) avg_load_run_time=$OPTARG ;;
        c) cool_off_period=$OPTARG ;;
        m) peak_load_min_threads=$OPTARG ;;
        M) peak_load_max_threads=$OPTARG ;;
        T) peak_load_run_time=$OPTARG ;;
        P) peak_load_probability=$OPTARG ;;
        C) peak_load_rerun_cool_off=$OPTARG ;;
        R) rampup_strategy=$OPTARG ;;
        r) rampup_run_time=$OPTARG ;;
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

# -O values (e.g. "--skip_trx:true --other_opt:val") are split into an
# array rather than left as an unquoted variable, so word-splitting is
# deliberate (one array element per option) instead of also being subject
# to glob expansion on whatever the user's -O value contains.
declare -a lua_script_opt_args=()
if [[ -n "$lua_script_opt" ]]; then
    read -ra lua_script_opt_args <<< "$lua_script_opt"
fi

if [[ ! -f "$LUA_SCRIPT" ]]; then
    die "${LUA_SCRIPT} not found in $(pwd)."
fi

if ! command -v sysbench >/dev/null 2>&1; then
    die "sysbench is not installed or not on PATH."
fi

if ! command -v psql >/dev/null 2>&1; then
    die "psql is not installed or not on PATH."
fi

# ---- Validation ---------------------------------------------------------------

require_int_in_range "$inventory_scale" 1 1000000000 "Inventory scale (-I)"
require_int_in_range "$user_scale" 1 1000000000 "User scale (-U)"
require_int_in_range "$items_per_order" 1 1000 "Items per order (-X)"
require_int_in_range "$avg_load_threads" "$avg_load_threads_min_limit" "$avg_load_threads_max_limit" "Average load threads (-N)"
require_int_in_range "$avg_load_run_time" "$avg_load_run_time_min_limit" "$avg_load_run_time_max_limit" "Average load run time (-t)"
require_int_in_range "$peak_load_min_threads" "$peak_load_min_threads_lower_limit" "$peak_load_min_threads_upper_limit" "Peak load minimum threads (-m)"
require_int_in_range "$peak_load_max_threads" "$peak_load_max_threads_lower_limit" "$peak_load_max_threads_upper_limit" "Peak load maximum threads (-M)"
require_int_in_range "$peak_load_run_time" "$peak_load_run_time_min_limit" "$peak_load_run_time_max_limit" "Peak load run time (-T)"
require_int_in_range "$cool_off_period" "$cool_off_period_min_limit" "$cool_off_period_max_limit" "Cool off period (-c)"
require_int_in_range "$peak_load_rerun_cool_off" "$peak_load_rerun_cool_off_min_limit" "$peak_load_rerun_cool_off_max_limit" "Peak load rerun cool off (-C)"
require_int_in_range "$peak_load_probability" "$peak_load_probability_min_limit" "$peak_load_probability_max_limit" "Peak load probability (-P)"
require_int_in_range "$rampup_run_time" "$rampup_run_time_min_limit" "$rampup_run_time_max_limit" "Rampup run time (-r)"
is_value_in_list "$rampup_strategy_valid_values" "$rampup_strategy" "Thread rampup strategy (-R)"

if (( peak_load_min_threads > peak_load_max_threads )); then
    die "Peak load minimum threads (-m ${peak_load_min_threads}) cannot exceed maximum threads (-M ${peak_load_max_threads})."
fi

if [[ "$rampup_strategy" == "linear" ]]; then
    thread_set="$linear_thread_set"
else
    thread_set="$exponential_thread_set"
fi

if ! mkdir -p "$output_dir"; then
    die "Unable to create output directory ${output_dir}."
fi

summary_file="${output_dir}/summary_writes.csv"
if ! echo "threads,run_time_sec,min_latency_ms,max_latency_ms,avg_latency_ms,p95_latency_ms,transactions_per_sec,queries_per_sec" > "$summary_file"; then
    die "Unable to write to summary file ${summary_file}."
fi

# ---- Main loop ----------------------------------------------------------------

log "Starting sporadic workload simulation against ${host}:${port}/${database}."
log "Average load: ${avg_load_threads} threads for ${avg_load_run_time}s, then cool off ${cool_off_period}s."
log "Peak load: ${peak_load_min_threads}-${peak_load_max_threads} threads (${rampup_strategy} rampup) for ${peak_load_run_time}s, ${peak_load_probability}% chance per cycle, min ${peak_load_rerun_cool_off}s apart."

while true; do
    if ! run_workload_cycle; then
        log "Workload cycle failed, exiting." >&2
        exit 1
    fi

    cleanup_between_runs
    log "Cooling off for ${cool_off_period}s before next cycle."
    sleep "$cool_off_period"
done
