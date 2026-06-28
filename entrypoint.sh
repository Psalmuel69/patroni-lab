#!/bin/bash
set -e

# Ensure the postgres user owns the data directory mount
if [ "$(id -u)" = '0' ]; then
    chown -R postgres:postgres /var/lib/postgresql/data
    # Drop privileges and execute Patroni
    exec gosu postgres patroni /etc/patroni.yml
fi

exec patroni /etc/patroni.yml
