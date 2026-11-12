# Crab Fit API built from source with the SQL adaptor (SQLite).
# Upstream's api/Dockerfile doesn't work as-is: rust:latest (trixie) builds
# against a newer glibc/libssl than its bullseye runtime, and the lockfile's
# time 0.3.21 fails to compile on Rust >= 1.80. So pin both to bookworm/1.79.
# sqlite-inline-fk.patch: the upstream migration adds the person->event FK
# with a separate ALTER, which SQLite can't do (panics on first start).

FROM docker.io/library/rust:1.79-bookworm AS builder
ARG CRABFIT_REF=628f9eefc300bf1ed3d6cc3323332c2ed9b8a350
WORKDIR /src
RUN git init -q . \
 && git remote add origin https://github.com/GRA0007/crab.fit.git \
 && git fetch -q --depth 1 origin "$CRABFIT_REF" \
 && git checkout -q FETCH_HEAD
COPY sqlite-inline-fk.patch /tmp/
RUN git apply /tmp/sqlite-inline-fk.patch
WORKDIR /src/api
RUN cargo build --release --locked --features sql-adaptor

FROM docker.io/library/debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3 \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -u 1000 -m app
COPY --from=builder /src/api/target/release/crabfit-api /app/api
USER app
WORKDIR /app
EXPOSE 3000
CMD ["/app/api"]
