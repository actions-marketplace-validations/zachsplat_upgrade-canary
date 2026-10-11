# The cache mount keeps the first MARK it ever saw. A normal rebuild with a new
# MARK still prints the old one; a build on a fresh builder prints the new one.
FROM busybox:1.38.0-musl
ARG MARK=unset
RUN --mount=type=cache,target=/cache sh -c '[ -f /cache/mark ] || echo "$MARK" > /cache/mark; cp /cache/mark /mark'
CMD ["cat", "/mark"]
