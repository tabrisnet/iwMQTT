ARG BUILD_FROM
FROM $BUILD_FROM
RUN apk add --no-cache --update perl-anyevent-http perl-module-pluggable perl-sub-name perl-yaml-tiny perl-json-xs


ADD entrypoint.sh /
RUN chmod +x /entrypoint.sh

# Build arguments
ARG BUILD_ARCH
ARG BUILD_DESCRIPTION
ARG BUILD_NAME
ARG BUILD_VERSION

# Labels
LABEL \
    io.hass.name="${BUILD_NAME}" \
    io.hass.description="${BUILD_DESCRIPTION}" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version=${BUILD_VERSION}

ENTRYPOINT ["/bin/sh", "-c", "/entrypoint.sh"]
