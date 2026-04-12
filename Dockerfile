# syntax=docker/dockerfile:1.7

FROM ubuntu:24.04 AS builder

LABEL maintainer="ueniueni, ueni"

ARG ARG_VERSION=1.0.0.0-dev
ARG COPY_ROOTFS_ARGS="--nss bin:/bin/bash bin:/usr/sbin/named bin:/usr/bin/getent bin:/usr/sbin/addgroup bin:/usr/sbin/adduser bin:/usr/bin/id bin:/usr/sbin/deluser bin:/usr/bin/find bin:/usr/bin/chown bin:/usr/bin/chgrp bin:/usr/bin/mkdir bin:/usr/bin/chmod"
ARG STRIP_SUID_SGID=1
ARG STRIP_CAPS=0
ENV FS=/rootfs
ENV VERSION=$ARG_VERSION

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get autoremove -y && \
    apt-get install -y \
        binutils \
        bind9 \
        bind9-utils

COPY copy-rootfs.sh /usr/local/bin/copy-rootfs.sh

RUN chmod +x /usr/local/bin/copy-rootfs.sh \
 && mkdir -p ${FS} \
 && /usr/local/bin/copy-rootfs.sh \
      --output-dir ${FS} \
      --manifest ${FS}/manifest.txt \
      ${COPY_ROOTFS_ARGS} \
 && if [ "${STRIP_SUID_SGID}" = "1" ]; then \
      find ${FS} -xdev \( -perm -4000 -o -perm -2000 \) -exec chmod ug-s '{}' +; \
    fi \
 && if [ "${STRIP_CAPS}" = "1" ] && command -v setcap >/dev/null 2>&1 && command -v getcap >/dev/null 2>&1; then \
      getcap -r ${FS} 2>/dev/null \
        | cut -d' ' -f1 \
        | while IFS= read -r f; do \
            [ -n "$f" ] || continue; \
            setcap -r "$f" || true; \
          done; \
    fi



FROM scratch
COPY --from=builder /rootfs/ /

VOLUME ["/etc/bind"]
VOLUME ["/var/cache/bind"]
VOLUME ["/var/log/named"]
VOLUME ["/var/usr/share/geoip"]
VOLUME ["/var/bind"]

EXPOSE 53/udp

COPY entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]
