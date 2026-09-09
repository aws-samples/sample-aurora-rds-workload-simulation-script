#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Function to display usage information
usage() {
    cat <<EOF
Usage: $0 [-f <file.lua>] [-b <table1,table2,...>] -u <username>[optional default "postgres"] -d <database>[optional default "postgres"] -h <host> -p <port>[optional default "5432"] -e <sysbench events>[optional default "1000"] -t <sysbench threads>[optional default "100"] [-w <password>] [-E <table1=events1,table2=events2,...>] [-O <script1.lua='--option-name:value',script2.lua='--option-name:value'>] [-o <output_dir>]

Prefer setting PGPASSWORD in the environment (export PGPASSWORD=...) instead
of -w: command-line arguments can be seen by other users on the same host
via /proc/<pid>/cmdline and may end up in shell history. -w is supported for
convenience but is not the preferred way to pass the password.
EOF
    exit 1
}

# Check if file exists in current directory
check_file_exists() {
    if [ ! -f "$1" ]; then
        echo "File $1 not found in the current directory."
        exit 1
    fi
}

# Initialize variables
lua_file=""
tables=""
username=""
database=""
port=""
password="${PGPASSWORD:-}"
output_dir="./output"
declare -A table_events=()  # Associative array to store table=events pairs
declare -A lua_options=()  # Associative array to store lua_script=options pairs

# Parse command line options
while getopts ":f:b:u:d:h:p:w:e:t:E:O:o:" opt; do
    case ${opt} in
        f)
            check_file_exists "$OPTARG"
            lua_file=$OPTARG
            ;;
        b)
            tables=$OPTARG
            ;;
        u)
            username=$OPTARG
            ;;
        d)
            database=$OPTARG
            ;;
        h)
            host=$OPTARG
            ;;
        p)
            port=$OPTARG
            ;;
        w)
            password=$OPTARG
            ;;
        e)
            events=$OPTARG
            ;;
        t)
            threads=$OPTARG
            ;;
        E)
            IFS=',' read -ra table_events_array <<< "$OPTARG"
            for entry in "${table_events_array[@]}"; do
                IFS='=' read -ra table_event_pair <<< "$entry"
                table_events["${table_event_pair[0]}"]="${table_event_pair[1]}"
            done
            ;;
        O)
            IFS=',' read -ra lua_options_array <<< "$OPTARG"
            for entry in "${lua_options_array[@]}"; do
                IFS='=' read -ra lua_options_pair <<< "$entry"
                lua_options["${lua_options_pair[0]}"]="${lua_options_pair[1]/:/=}"
            done
            ;;
        o)
            output_dir=$OPTARG
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            usage
            ;;
    esac
done
shift $((OPTIND -1))

# Check if all required options are provided
if [[ -z $host || -z $password ]]; then
    echo "Missing required options."
    usage
fi

# Set default values for parameters not passed
default_username="test_user"
default_database="testdb"
default_port="5432"
default_events="10000"
default_threads="100"

username=${username:-$default_username}
database=${database:-$default_database}
port=${port:-$default_port}
events=${events:-$default_events}
threads=${threads:-$default_threads}

if ! command -v sysbench >/dev/null 2>&1; then
    echo "Error: sysbench is not installed or not on PATH." >&2
    exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
    echo "Error: psql is not installed or not on PATH." >&2
    exit 1
fi

if ! mkdir -p "$output_dir"; then
    echo "Error: Unable to create output directory ${output_dir}." >&2
    exit 1
fi

# Function to run sysbench for a single file
run_sysbench_file() {
    local file=$1
    local file_name
    file_name=$(basename "$file" .lua)
    local events_value=${table_events[$file_name]:-$events}
    local lua_script_opt=${lua_options[$file_name]:-}
    local log_file="${output_dir}/refresh_db_${file_name}_$(date +%Y%m%d%H%M%S).log"

    # -O values (e.g. "--batch_size:1000 --other_opt:val") are split into an
    # array rather than left as an unquoted variable, so word-splitting is
    # deliberate (one array element per option) instead of also being
    # subject to glob expansion on whatever the user's -O value contains.
    local -a lua_script_opt_args=()
    if [[ -n "$lua_script_opt" ]]; then
        read -ra lua_script_opt_args <<< "$lua_script_opt"
    fi

    echo "Processing sysbench with $events_value events and $threads threads for $file"
    echo "Logging sysbench output to ${log_file}"
    PGPASSWORD="$password" sysbench --db-driver=pgsql --pgsql-host="$host" --pgsql-user="$username" --pgsql-db="$database" --pgsql-port="$port" --pgsql-password="$password" --threads="$threads" --events="$events_value" --time=0 "${lua_script_opt_args[@]}" "$file" run > "$log_file" 2>&1
}

# Function to run sysbench for a list of tables
run_sysbench_tables() {
    local tables=$1
    IFS=',' read -ra table_array <<< "$tables"
    for table in "${table_array[@]}"; do
        local file="${table}.lua"
        if [ -f "$file" ]; then
            run_sysbench_file "$file"
        else
            echo "Error: File $file not found in the current directory." >&2
            exit 1
        fi
    done
}

# Run sysbench for the specified file or tables
if [ -n "$lua_file" ]; then
    run_sysbench_file "$lua_file"
fi

if [ -n "$tables" ]; then
    run_sysbench_tables "$tables"
fi

# Run vacuum and analyze commands
vacuum_commands=(
    "with row_num as (select row_number() over(partition by item_category) as rn, inventory_id as item_id from item_inventory) update item_inventory set popularity_rank=rn from row_num where item_id=inventory_id ;"
    "vacuum full freeze analyze item_inventory"
    "vacuum freeze analyze orders"
    "vacuum freeze analyze order_items"
)

for cmd in "${vacuum_commands[@]}"; do
    if ! PGPASSWORD="$password" psql -h "$host" -p "$port" -U "$username" -d "$database" -c "$cmd"; then
        echo "Error: Failed to run: $cmd" >&2
        exit 1
    fi
done
