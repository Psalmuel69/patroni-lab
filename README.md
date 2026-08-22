# patroni-lab

A local, disposable **PostgreSQL High Availability (HA) cluster** built with [Patroni](https://patroni.readthedocs.io/), [etcd](https://etcd.io/), and [HAProxy](https://www.haproxy.org/), fully orchestrated with Docker Compose.

This lab spins up a 3-node Patroni/PostgreSQL cluster with automatic leader election and failover, fronted by a load balancer that always routes read-write traffic to the current primary and read-only traffic to the replicas.

## Architecture

```
                         ┌───────────────┐
                         │     etcd      │  ← Distributed Configuration
                         │  (port 2379)  │    Store (DCS) / leader lock
                         └───────┬───────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
      ┌───────▼──────┐   ┌───────▼──────┐   ┌───────▼──────┐
      │   patroni1   │   │   patroni2   │   │   patroni3   │
      │  Patroni +   │   │  Patroni +   │   │  Patroni +   │
      │ PostgreSQL16 │   │ PostgreSQL16 │   │ PostgreSQL16 │
      └───────┬──────┘   └───────┬──────┘   └───────┬──────┘
              │                  │                  │
              └──────────────────┼──────────────────┘
                                 │
                         ┌───────▼───────┐
                         │    HAProxy    │
                         │ 5000 → primary│
                         │ 5001 → replica│
                         │ 7000 → stats  │
                         └───────────────┘
```

- **etcd** acts as the Distributed Configuration Store (DCS) that Patroni uses to hold the leader lock and cluster state.
- **patroni1 / patroni2 / patroni3** are identical containers, each running Patroni as a supervisor around a PostgreSQL 16 instance. Patroni handles bootstrapping, streaming replication, health checks, and automatic failover/promotion.
- **HAProxy** health-checks each node's Patroni REST API (`/master` and `/replica`) and routes client traffic accordingly, so applications can always connect to the correct role without knowing which node is currently primary.

## Project structure

```
patroni-lab/
├── docker-compose.yml     # etcd, patroni1-3, haproxy services
├── dockerfile             # Patroni + PostgreSQL 16 image definition
├── entrypoint.sh          # Fixes data dir ownership, drops to postgres, execs patroni
├── haproxy/
│   └── haproxy.cfg        # Primary/replica routing + stats dashboard
├── node1/
│   └── patroni.yml        # Patroni config for patroni1
├── node2/
│   └── patroni.yml        # Patroni config for patroni2
└── node3/
    └── patroni.yml        # Patroni config for patroni3
```

Each `patroniN/patroni.yml` defines the node's scope (`mycluster`), REST API address, etcd endpoint, bootstrap/replication parameters, and PostgreSQL connection details.

## Prerequisites

- Docker
- Docker Compose (v2 CLI, i.e. `docker compose`)

## Quick start

Clone the repo and start the stack:

```bash
git clone https://github.com/Psalmuel69/patroni-lab.git
cd patroni-lab
docker compose up -d --build
```

This builds the custom Patroni/PostgreSQL image once and starts 5 containers: `etcd`, `patroni1`, `patroni2`, `patroni3`, and `haproxy`.

Give the cluster a few seconds to bootstrap, then check who the leader is:

```bash
curl http://localhost:8008/master   # 200 = primary
curl http://localhost:8009/master   # 200 = primary, 503 = not primary
curl http://localhost:8010/master   # 200 = primary, 503 = not primary
```

## Port map

| Service   | Container port | Host port | Purpose                                   |
|-----------|-----------------|-----------|--------------------------------------------|
| etcd      | 2379            | 2379      | DCS client API                             |
| patroni1  | 8008 (REST)     | 8008      | Patroni REST API / health checks           |
| patroni1  | 5432 (Postgres) | 15432     | Direct PostgreSQL connection to node 1     |
| patroni2  | 8008 (REST)     | 8009      | Patroni REST API / health checks           |
| patroni2  | 5432 (Postgres) | 15433     | Direct PostgreSQL connection to node 2     |
| patroni3  | 8008 (REST)     | 8010      | Patroni REST API / health checks           |
| patroni3  | 5432 (Postgres) | 15434     | Direct PostgreSQL connection to node 3     |
| haproxy   | 5000            | 5000      | Read-write endpoint → current primary      |
| haproxy   | 5001            | 5001      | Read-only endpoint → replicas              |
| haproxy   | 7000            | 7000      | HAProxy stats dashboard (`/`)              |

## Connecting

**Via HAProxy (recommended — always hits the right node):**

```bash
# Read-write, always the current primary
psql -h localhost -p 5000 -U postgres -d postgres

# Read-only, load balanced across replicas
psql -h localhost -p 5001 -U postgres -d postgres
```

**Directly to a specific node** (useful for inspecting replication state):

```bash
psql -h localhost -p 15432 -U postgres -d postgres   # patroni1
psql -h localhost -p 15433 -U postgres -d postgres   # patroni2
psql -h localhost -p 15434 -U postgres -d postgres   # patroni3
```

**Default credentials** (defined in `patroni.yml`, dev-only — change before using this anywhere real):

| User          | Password       | Role                  |
|---------------|----------------|------------------------|
| `postgres`    | `postgrespass` | Superuser              |
| `replicator`  | `replpass`     | Streaming replication  |

**HAProxy stats dashboard:** open `http://localhost:7000/` in a browser to see live health status of all three nodes.

## Managing the cluster with `patronictl`

You can run `patronictl` from inside any node container:

```bash
docker exec -it patroni1 patronictl -c /etc/patroni.yml list
```

This shows each member's role (`Leader` / `Replica`), state, and replication lag.

Other useful commands:

```bash
docker exec -it patroni1 patronictl -c /etc/patroni.yml topology
docker exec -it patroni1 patronictl -c /etc/patroni.yml switchover
docker exec -it patroni1 patronictl -c /etc/patroni.yml history
```

## Testing failover

1. Confirm the current primary with `patronictl list` or `curl localhost:8008/master`.
2. Kill it: `docker stop patroni1` (adjust to whichever node is currently the leader).
3. Watch Patroni promote a replica — usually within a few seconds (governed by `ttl`/`loop_wait` in `patroni.yml`).
4. Verify HAProxy has already re-routed traffic: `curl http://localhost:5000` should keep working against the new primary without any client-side changes.
5. Bring the old node back: `docker start patroni1`. It will rejoin the cluster as a replica and stream from the new leader (using `pg_rewind` if needed).

## Resetting the lab

To wipe all cluster state and start fresh:

```bash
docker compose down -v
docker compose up -d --build
```

The `-v` flag removes the `pgdata1`, `pgdata2`, and `pgdata3` volumes along with etcd's state, so the cluster re-bootstraps from scratch.

## How it works

- **`dockerfile`** builds on `postgres:16` and installs Patroni (`patroni[etcd3]`), `psycopg2-binary`, and supporting tools (`gosu`, `netcat`, `curl`).
- **`entrypoint.sh`** runs as root first to fix ownership of the mounted data volume, then drops privileges to the `postgres` user via `gosu` and execs `patroni /etc/patroni.yml`.
- Each node mounts its own `patroni.yml` and a dedicated named volume (`pgdata1`/`pgdata2`/`pgdata3`) so data persists across container restarts but is isolated per node.
- **`haproxy.cfg`** defines two `listen` blocks that both check every node's Patroni REST API on port 8008 (`/master` and `/replica` respectively) but forward actual traffic to PostgreSQL on port 5432 — so routing decisions are driven by Patroni's view of cluster state, not HAProxy's own logic.

## Known issues

- `node3/patroni.yml` has its `restapi.connect_address` set to `patroni1:8008` instead of `patroni3:8008` — worth fixing if you hit odd behavior with node 3's REST API being addressed correctly by peers.

## License

No license file is currently included in this repository. Add one (e.g. MIT) if you intend for others to reuse this lab.
