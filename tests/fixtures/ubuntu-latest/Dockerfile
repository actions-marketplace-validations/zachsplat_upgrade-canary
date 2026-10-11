# A typical ubuntu:latest image: a few runtime packages and a tool.
FROM ubuntu:latest
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
CMD ["curl", "--version"]
