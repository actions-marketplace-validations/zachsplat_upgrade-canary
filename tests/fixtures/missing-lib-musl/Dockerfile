# Fails: same as missing-lib-glibc on musl.
FROM alpine:3.22 AS build
RUN apk add --no-cache curl

FROM alpine:3.22
COPY --from=build /usr/bin/curl /usr/local/bin/curl
CMD ["curl", "--version"]
