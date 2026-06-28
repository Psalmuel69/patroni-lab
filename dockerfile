FROM postgres:16

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3-pip \
        python3-venv \
        curl \
        netcat-openbsd \
        gosu \
    && pip3 install --break-system-packages \
        patroni[etcd3] \
        psycopg2-binary \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/patroni && chown -R postgres:postgres /etc/patroni

WORKDIR /

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
