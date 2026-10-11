# Fails: the runtime stage copies the curl binary but not libcurl, the same
# shape as a builder that links a library the runtime stage does not carry.
FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

FROM debian:bookworm-slim
COPY --from=build /usr/bin/curl /usr/local/bin/curl
CMD ["curl", "--version"]
