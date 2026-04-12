# syntax=docker/dockerfile:1.7

FROM ubuntu:24.04 AS builder

LABEL maintainer="ueniueni, ueni"

ARG ARG_VERSION=1.0.0.0-dev
ARG COPY_ROOTFS_ARGS="--nss --ldd-fast bin:/bin/bash bin:/usr/sbin/named bin:named-checkconf bin:/usr/bin/chown bin:/usr/bin/chmod bin:/usr/bin/mkdir /etc/bind /usr/share/dns/root.hints"
ARG STRIP_SUID_SGID=1
ARG STRIP_CAPS=0
ENV FS=/rootfs
ENV VERSION=$ARG_VERSION

SHELL ["/bin/bash", "-ec"]

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y \
        binutils \
        bind9 \
        bind9-utils \
        tree 

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY copy-rootfs.sh /usr/local/bin/copy-rootfs.sh

RUN chmod +x /usr/local/bin/copy-rootfs.sh /usr/local/bin/entrypoint.sh \
 && mkdir -p ${FS} \
 && /usr/local/bin/copy-rootfs.sh \
      --sysroot / \
      --output-dir ${FS} \
      --manifest ${FS}/manifest.txt \
      /usr/local/bin/entrypoint.sh \
      ${COPY_ROOTFS_ARGS} \
 && mkdir -p ${FS}/run \
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

SHELL ["/bin/bash", "-ec"]

ARG ARG_VERSION=1.0.0.0-dev
ENV IMAGE_VERSION=${ARG_VERSION}

ENV HOME=/nonexistent
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

VOLUME ["/etc/bind"]
VOLUME ["/var/cache/bind"]
VOLUME ["/var/log/named"]
VOLUME ["/var/usr/share/geoip"]
VOLUME ["/var/bind"]

EXPOSE 53/udp

ENTRYPOINT ["/bin/bash", "-c","/usr/local/bin/entrypoint.sh"]
