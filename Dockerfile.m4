m4_changequote([[, ]])

##################################################
## "build" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM docker.io/CROSS_ARCH/alpine:3]], [[FROM docker.io/alpine:3]]) AS build
m4_ifdef([[CROSS_QEMU]], [[COPY --from=docker.io/hectormolinero/qemu-user-static:latest CROSS_QEMU CROSS_QEMU]])

# Install system packages
RUN apk add --no-cache \
		build-base \
		ca-certificates \
		curl \
		perl

# Switch to unprivileged user
ENV USER=builder GROUP=builder
RUN addgroup -S "${GROUP:?}"
RUN adduser -S -G "${GROUP:?}" "${USER:?}"
USER "${USER}:${GROUP}"

# Build Busybox
ARG BUSYBOX_VERSION=1.32.0
ARG BUSYBOX_TARBALL_URL=https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
ARG BUSYBOX_TARBALL_CHECKSUM=c35d87f1d04b2b153d33c275c2632e40d388a88f19a9e71727e0bbbff51fe689
RUN mkdir /tmp/busybox/
WORKDIR /tmp/busybox/
RUN curl -Lo /tmp/busybox.tbz2 "${BUSYBOX_TARBALL_URL:?}"
RUN printf '%s' "${BUSYBOX_TARBALL_CHECKSUM:?}  /tmp/busybox.tbz2" | sha256sum -c
RUN tar -xjf /tmp/busybox.tbz2 --strip-components=1 -C /tmp/busybox/
RUN make allnoconfig
RUN setcfg() { sed -ri "s/^(# )?(${1:?})( is not set|=.*)$/\2=${2?}/" ./.config; } \
	&& setcfg CONFIG_STATIC          y \
	&& setcfg CONFIG_LFS             y \
	&& setcfg CONFIG_BUSYBOX         y \
	&& setcfg CONFIG_SH_IS_ASH       n \
	&& setcfg CONFIG_SH_IS_HUSH      y \
	&& setcfg CONFIG_SH_IS_NONE      n \
	&& setcfg CONFIG_BASH_IS_ASH     n \
	&& setcfg CONFIG_BASH_IS_HUSH    n \
	&& setcfg CONFIG_BASH_IS_NONE    y \
	&& setcfg CONFIG_HUSH            y \
	&& setcfg CONFIG_HUSH_[A-Z0-9_]+ n \
	&& grep -v '^#' ./.config | sort | uniq
RUN make -j"$(nproc)"
RUN make install
RUN ./_install/bin/busybox

# Build rsync
ARG RSYNC_VERSION=3.1.3
ARG RSYNC_TARBALL_URL=https://download.samba.org/pub/rsync/src/rsync-${RSYNC_VERSION}.tar.gz
ARG RSYNC_TARBALL_CHECKSUM=55cc554efec5fdaad70de921cd5a5eeb6c29a95524c715f3bbf849235b0800c0
RUN mkdir /tmp/rsync/
WORKDIR /tmp/rsync/
RUN curl -Lo /tmp/rsync.tgz "${RSYNC_TARBALL_URL:?}"
RUN printf '%s' "${RSYNC_TARBALL_CHECKSUM:?}  /tmp/rsync.tgz" | sha256sum -c
RUN tar -xzf /tmp/rsync.tgz --strip-components=1 -C /tmp/rsync/
RUN ./configure CFLAGS='-static'
RUN make -j"$(nproc)"
RUN ./rsync --version

##################################################
## "sftp" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM docker.io/CROSS_ARCH/ubuntu:18.04]], [[FROM docker.io/ubuntu:18.04]]) AS sftp
m4_ifdef([[CROSS_QEMU]], [[COPY --from=docker.io/hectormolinero/qemu-user-static:latest CROSS_QEMU CROSS_QEMU]])

# Install system packages
RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		locales \
		openssh-client \
		openssh-server \
		passwd \
		tzdata \
	&& rm -rf \
		/etc/ssh/ssh_host_* \
		/var/lib/apt/lists/*

# Setup locale
RUN printf '%s\n' 'en_US.UTF-8 UTF-8' > /etc/locale.gen
RUN localedef -c -i en_US -f UTF-8 en_US.UTF-8 ||:
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Setup timezone
ENV TZ=UTC
RUN ln -snf "/usr/share/zoneinfo/${TZ:?}" /etc/localtime
RUN printf '%s\n' "${TZ:?}" > /etc/timezone

### USERNAME:PASSWORD:(plain|encrypted):UID:GID:[dir1,dir2,dir3,...] ...
ENV SFTP_USERS=

# Create "ssh-user" group
RUN groupadd --gid 999 ssh-user

# Create "/run/sshd/" directory
RUN mkdir /run/sshd/

# Create "/etc/skel/" directory
RUN rm -rf /etc/skel/ && mkdir /etc/skel/
COPY --from=build --chown=root:root /tmp/busybox/_install/bin/ /etc/skel/bin/
COPY --from=build --chown=root:root /tmp/rsync/rsync /etc/skel/bin/rsync.real
# rsync requires "--fake-super" option to avoid problems when establishing permissions in chrooted
# environments (if you, reader, know some workaround for this, I would be pleased if you open an issue)
# https://gitlab.alpinelinux.org/alpine/aports/issues/4963
RUN printf '%s\n' '#!/bin/sh' 'rsync.real --fake-super "$@"' > /etc/skel/bin/rsync && chmod 755 /etc/skel/bin/rsync

# Disable MOTD
RUN sed -i 's|^\(.*pam_motd\.so.*\)$|#\1|g' /etc/pam.d/sshd

# Copy SSH config
COPY --chown=root:root ./config/ssh/ /etc/ssh/
RUN chmod 644 /etc/ssh/sshd_config

# Copy scripts
COPY --chown=root:root ./scripts/bin/ /usr/local/bin/
RUN chmod 755 /usr/local/bin/*

# Expose SSH port
EXPOSE 22/tcp

CMD ["/usr/local/bin/container-foreground-cmd"]
