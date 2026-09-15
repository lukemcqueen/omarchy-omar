# Article: A Core on Fire for Nothing — ClickHouse Trace Logging in Langfuse

*Field note, 2026-09-15: a langfuse ClickHouse container burned one CPU core
sustained, with zero queries and zero merges running.*

## The symptom

`docker stats` shows the langfuse ClickHouse container at **20-35% CPU**,
hours on end, on a box where nothing else is loading it. `top`/`ps` agree.
The container has been up for days and the CPU is not startup work.

## Root cause

The container's `/etc/clickhouse-server/config.xml` ships the main log level
at `<level>trace</level>` — the most verbose setting. ClickHouse background
workers then log continuously into its internal system tables
(`system.text_log`, `system.trace_log`, `system.metric_log`, ...); at trace
level that churn becomes sustained CPU both from writing and from the merge
loops that keep pacing the growing tables. Nothing in langfuse reads those
tables. Probe: `clickhouse-client --query "SELECT count() FROM system.processes"`
returns just your own probe — **no real work == spin.**

## Fix

Override the level to `warning` and drop the bloated system tables:

```bash
cat > /tmp/01-log-level.xml <<'XML'
<?xml version="1.0"?>
<clickhouse><logger><level>warning</level></logger></clickhouse>
XML
docker cp /tmp/01-log-level.xml langfuse-clickhouse-1:/etc/clickhouse-server/config.d/01-log-level.xml
docker exec langfuse-clickhouse-1 chown clickhouse:clickhouse /etc/clickhouse-server/config.d/01-log-level.xml
docker exec langfuse-clickhouse-1 kill -HUP 1
docker exec langfuse-clickhouse-1 clickhouse-client --query "TRUNCATE TABLE system.text_log"
docker exec langfuse-clickhouse-1 clickhouse-client --query "TRUNCATE TABLE system.trace_log"
docker exec langfuse-clickhouse-1 clickhouse-client --query "TRUNCATE TABLE system.asynchronous_metric_log"
docker exec langfuse-clickhouse-1 clickhouse-client --query "TRUNCATE TABLE system.metric_log"
```

`docker cp` lands the file owned by the caller's uid; ClickHouse runs as uid
101 — **always `chown clickhouse:clickhouse` after copying**, or the override
is unreadable and silently ignored.

**Persistence:** the `config.d/` file lives only inside the running container
— pin it in the compose file so it survives recreation:

```yaml
services:
  clickhouse:
    volumes:
      - ./clickhouse-config.d/01-log-level.xml:/etc/clickhouse-server/config.d/01-log-level.xml:ro
```

## Status

Found 2026-09-15; remediation prepared, application pending operator go-ahead.