# aria2, and nothing else, for librariand's Fetch tab.
#
# Built here rather than pulled from a third-party image: this is the one
# container that handles torrent traffic, so the less code in it that nobody
# here has read, the better. Alpine's package is the whole of it.
#
# Rebuild to pick up a newer aria2:
#
#   docker compose --profile torrents build --pull aria2
FROM alpine:3.22
RUN apk add --no-cache aria2
COPY run.sh /run.sh
ENTRYPOINT ["/bin/sh", "/run.sh"]
