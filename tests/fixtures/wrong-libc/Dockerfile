# Fails: a musl executable in a glibc image, whose interpreter
# /lib/ld-musl-x86_64.so.1 does not exist there.
FROM alpine:3.22 AS build

FROM debian:bookworm-slim
COPY --from=build /bin/busybox /usr/local/bin/alpine-busybox
CMD ["/usr/local/bin/alpine-busybox", "true"]
