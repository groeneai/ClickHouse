#!/usr/bin/env bash
# Tags: no-fasttest
# Tag no-fasttest: requires `IcebergLocal` (USE_AVRO build option) and Iceberg writes.

# An INSERT into an Iceberg table reads the parent manifest list. A recursive Avro schema there must be an error, not a crash.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

WORK_DIR="${CLICKHOUSE_TMP}/iceberg_recursive_manifest_list_writer_${CLICKHOUSE_TEST_UNIQUE_NAME}"
rm -rf "${WORK_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Arguments: case name, Avro schema, nesting depth of the file's single row (0 = no rows).
run_case()
{
    local dir="${WORK_DIR}/$1"
    mkdir -p "${dir}/db" "${dir}/t0"
    ${CLICKHOUSE_LOCAL} --path "${dir}/db" --allow_insert_into_iceberg=1 --query "
        CREATE TABLE t0 (x Int32) ENGINE = IcebergLocal('${dir}/t0/');
        INSERT INTO t0 VALUES (1);" -- --user_files_path="${dir}"

    python3 - "${dir}/crafted.avro" "$2" "$3" <<'PY'
import sys

def long(v):
    v <<= 1
    out = b''
    while v > 0x7F:
        out += bytes([v & 0x7F | 0x80])
        v >>= 7
    return out + bytes([v])

def blob(v):
    return long(len(v)) + v

path, schema, depth = sys.argv[1], sys.argv[2].encode(), int(sys.argv[3])
sync = b'\x00' * 16
data = b'Obj\x01' + long(2) + blob(b'avro.codec') + blob(b'null') + blob(b'avro.schema') + blob(schema) + long(0) + sync
if depth:
    data += long(1) + blob(b'\x02' * depth + b'\x00') + sync
open(path, 'wb').write(data)
PY

    # The SELECT caches the valid manifest list, so only the INSERT reads the replaced file.
    ${CLICKHOUSE_LOCAL} --path "${dir}/db" --allow_insert_into_iceberg=1 --use_iceberg_metadata_files_cache=1 \
        --engine_file_truncate_on_insert=1 --query "
        SELECT count() FROM t0 FORMAT Null;
        INSERT INTO FUNCTION file('$(find "${dir}/t0/metadata" -name 'snap-*.avro')', RawBLOB)
            SELECT * FROM file('${dir}/crafted.avro', RawBLOB);
        INSERT INTO t0 VALUES (2);" -- --user_files_path="${dir}" 2>&1 \
        | grep -o -m1 'Cannot [a-z]* a datum nested deeper than 256 levels. (AVRO_EXCEPTION)' || echo 'no depth error'
}

run_case recursive '{"type":"record","name":"A","fields":[{"name":"b","type":{"type":"record","name":"B","fields":[{"name":"a","type":"A"}]}}]}' 0
run_case deep '{"type":"record","name":"A","fields":[{"name":"next","type":["null","A"]}]}' 1000000
