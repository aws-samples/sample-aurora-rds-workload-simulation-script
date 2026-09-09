#!/bin/bash
#
# copy_item_inventory_to_striped.sh
#
# Copies data from item_inventory into item_inventory_striped, splitting
# each item's item_count across <stripe_count> rows ("stripes") instead of
# one. This lets writers pick a random stripe row per update instead of
# always updating the same item_inventory row, reducing row lock contention.
#
# For a given item with item_count C and stripe_count N:
#   - stripes 1..N-1 each get floor(C / N)
#   - the final stripe (N) gets the remainder: C - floor(C / N) * (N - 1)
#
# Example: C=365, N=20 -> stripes 1-19 each get 18 (floor(365/20)),
# stripe 20 gets 365 - 18*19 = 23.
#
# Also (re)creates item_inventory_striping_config, which records how many
# stripes each inventory_id was split into (all default to 20 unless -n is
# used to override).
#
# Both item_inventory_striped and item_inventory_striping_config are
# recreated from scratch on every run, so this script is safe to re-run
# after item_inventory changes.
#
# Example:
#   ./copy_item_inventory_to_striped.sh -h "$PGHOST" -w "$PGPASSWORD"

set -euo pipefail

readonly default_username="test_user"
readonly default_database="testdb"
readonly default_port="5432"
readonly default_stripe_count=20

usage() {
    cat <<EOF
Usage: $0 -h <host> -w <password> [options]

Copies item_inventory into item_inventory_striped, splitting each item's
item_count across <stripe_count> rows to reduce update contention, and
(re)populates item_inventory_striping_config with the stripe count used
for each inventory_id.

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
  -n <stripe_count>      Number of stripe rows per item [default: ${default_stripe_count}]
EOF
    exit 1
}

username="$default_username"
database="$default_database"
port="$default_port"
stripe_count="$default_stripe_count"
host=""
password="${PGPASSWORD:-}"

while getopts ":h:w:u:d:p:n:" opt; do
    case ${opt} in
        h) host=$OPTARG ;;
        w) password=$OPTARG ;;
        u) username=$OPTARG ;;
        d) database=$OPTARG ;;
        p) port=$OPTARG ;;
        n) stripe_count=$OPTARG ;;
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

if ! [[ "$stripe_count" =~ ^[0-9]+$ ]] || (( stripe_count < 1 )); then
    echo "Error: -n <stripe_count> must be a positive integer, got '${stripe_count}'." >&2
    usage
fi

if ! command -v psql >/dev/null 2>&1; then
    echo "Error: psql is not installed or not on PATH." >&2
    exit 1
fi

log() {
    echo "$(date '+%H:%M:%S'): $*"
}

run_psql() {
    if ! PGPASSWORD="$password" psql -v ON_ERROR_STOP=1 -h "$host" -p "$port" -U "$username" -d "$database" -c "$1"; then
        echo "Error: Failed to run: $1" >&2
        exit 1
    fi
}

log "Recreating item_inventory_striped and item_inventory_striping_config."

run_psql "DROP TABLE IF EXISTS item_inventory_striping_config;"
run_psql "DROP TABLE IF EXISTS item_inventory_striped;"

run_psql "CREATE TABLE item_inventory_striped (
    idpk bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    inventory_id bigint NOT NULL,
    item_name character varying(255) NOT NULL,
    item_count integer,
    item_category integer,
    dttm timestamp without time zone,
    popularity_rank bigint,
    item_stripe_id int DEFAULT '1'
);"

run_psql "CREATE TABLE item_inventory_striping_config (
    inventory_id bigint NOT NULL PRIMARY KEY,
    stripe_count int NOT NULL DEFAULT 20
);"

log "Copying item_inventory into item_inventory_striped across ${stripe_count} passes (stripe_id 1..${stripe_count})."

for (( pass=1; pass<=stripe_count; pass++ )); do
    if (( pass < stripe_count )); then
        item_count_expr="item_count / ${stripe_count}"
    else
        # Final pass gets the remainder, so the sum of all stripes for an
        # item always equals its original item_count exactly.
        item_count_expr="item_count - (item_count / ${stripe_count}) * (${stripe_count} - 1)"
    fi

    log "Pass ${pass}/${stripe_count}: inserting stripe_id=${pass} (item_count = ${item_count_expr})."

    run_psql "INSERT INTO item_inventory_striped
        (inventory_id, item_name, item_count, item_category, dttm, popularity_rank, item_stripe_id)
        SELECT inventory_id, item_name, ${item_count_expr}, item_category, dttm, popularity_rank, ${pass}
        FROM item_inventory;"
done

log "Populating item_inventory_striping_config (stripe_count=${stripe_count} for all items)."

run_psql "INSERT INTO item_inventory_striping_config (inventory_id, stripe_count)
    SELECT inventory_id, ${stripe_count} FROM item_inventory;"

log "Creating indexes on item_inventory_striped."

run_psql "CREATE INDEX idx_inventory_striped_rank ON item_inventory_striped USING btree (item_category, popularity_rank DESC);"
run_psql "CREATE UNIQUE INDEX unq_idx_inventory_stripe ON item_inventory_striped USING btree (inventory_id, item_stripe_id);"

log "Done. item_inventory_striped and item_inventory_striping_config are ready."
