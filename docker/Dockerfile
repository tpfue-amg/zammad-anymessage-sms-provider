# Zammad image with the AnyMessage SMS provider built in.
# Build from the repository root:
#   docker build -f docker/Dockerfile --build-arg ZAMMAD_VERSION=7.2.0-0011 -t zammad-anymessage:7.2.0-0011 .

ARG ZAMMAD_IMAGE=ghcr.io/zammad/zammad
ARG ZAMMAD_VERSION=7.2.0-0011

FROM ${ZAMMAD_IMAGE}:${ZAMMAD_VERSION}

COPY --chown=1000:1000 app/    /opt/zammad/app/
COPY --chown=1000:1000 config/ /opt/zammad/config/
