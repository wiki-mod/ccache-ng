ARG BASE_IMAGE=debian:13
FROM ${BASE_IMAGE}

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        procps \
        redis-server \
        redis-tools \
        util-linux \
 && rm -rf /var/lib/apt/lists/*

COPY redis-cache-entrypoint.sh /usr/local/bin/redis-cache-entrypoint
RUN chmod 0755 /usr/local/bin/redis-cache-entrypoint

EXPOSE 6379
ENTRYPOINT ["/usr/local/bin/redis-cache-entrypoint"]
