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
		lz4-dev \
		lz4-static \
		openssl-dev \
		openssl-libs-static \
		perl \
		zlib-dev \
		zlib-static \
		zstd-dev \
		zstd-static

# Switch to unprivileged user
ENV USER=builder GROUP=builder
RUN addgroup -S "${GROUP:?}"
RUN adduser -S -G "${GROUP:?}" "${USER:?}"
USER "${USER}:${GROUP}"

# Build Busybox
ARG BUSYBOX_VERSION=1.33.1
ARG BUSYBOX_TARBALL_URL=https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
ARG BUSYBOX_TARBALL_CHECKSUM=12cec6bd2b16d8a9446dd16130f2b92982f1819f6e1c5f5887b6db03f5660d28
RUN mkdir /tmp/busybox/
WORKDIR /tmp/busybox/
RUN curl -Lo /tmp/busybox.tbz2 "${BUSYBOX_TARBALL_URL:?}"
RUN printf '%s' "${BUSYBOX_TARBALL_CHECKSUM:?}  /tmp/busybox.tbz2" | sha256sum -c
RUN tar -xjf /tmp/busybox.tbz2 --strip-components=1 -C /tmp/busybox/
RUN make allnoconfig
RUN setcfg() { sed -ri "s/^(# )?(${1:?})( is not set|=.*)$/\2=${2?}/" ./.config; } \
	&& setcfg CONFIG_STATIC                y \
	&& setcfg CONFIG_LFS                   y \
	&& setcfg CONFIG_BUSYBOX               y \
	&& setcfg CONFIG_FEATURE_SH_STANDALONE y \
	&& setcfg CONFIG_SH_IS_[A-Z0-9_]+      n \
	&& setcfg CONFIG_SH_IS_ASH             y \
	&& setcfg CONFIG_BASH_IS_[A-Z0-9_]+    n \
	&& setcfg CONFIG_BASH_IS_NONE          y \
	&& setcfg CONFIG_ASH                   y \
	&& setcfg CONFIG_ASH_[A-Z0-9_]+        n \
	&& setcfg CONFIG_ASH_PRINTF            y \
	&& setcfg CONFIG_ASH_TEST              y \
	&& grep -v '^#' ./.config | sort | uniq
RUN make -j "$(nproc)" && make install
RUN test -z "$(readelf -x .interp ./_install/bin/busybox 2>/dev/null)"
RUN strip -s ./_install/bin/busybox

# Build rsync
ARG RSYNC_VERSION=3.2.3
ARG RSYNC_TARBALL_URL=https://download.samba.org/pub/rsync/src/rsync-${RSYNC_VERSION}.tar.gz
ARG RSYNC_TARBALL_CHECKSUM=becc3c504ceea499f4167a260040ccf4d9f2ef9499ad5683c179a697146ce50e
RUN mkdir /tmp/rsync/
WORKDIR /tmp/rsync/
RUN curl -Lo /tmp/rsync.tgz "${RSYNC_TARBALL_URL:?}"
RUN printf '%s' "${RSYNC_TARBALL_CHECKSUM:?}  /tmp/rsync.tgz" | sha256sum -c
RUN tar -xzf /tmp/rsync.tgz --strip-components=1 -C /tmp/rsync/
RUN ./configure CFLAGS='-static' LDFLAGS='-static' --disable-xxhash
RUN make -j "$(nproc)"
RUN test -z "$(readelf -x .interp ./rsync 2>/dev/null)"
RUN strip -s ./rsync

##################################################
## "sftp" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM docker.io/CROSS_ARCH/ubuntu:20.04]], [[FROM docker.io/ubuntu:20.04]]) AS sftp
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
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
RUN printf '%s\n' "${LANG:?} UTF-8" > /etc/locale.gen \
	&& localedef -c -i "${LANG%%.*}" -f UTF-8 "${LANG:?}" ||:

# Setup timezone
ENV TZ=UTC
RUN printf '%s\n' "${TZ:?}" > /etc/timezone \
	&& ln -snf "/usr/share/zoneinfo/${TZ:?}" /etc/localtime

# Create "ssh-user" group
RUN groupadd --gid 999 ssh-user

# Create "/etc/sftp/" and "/run/sshd/" directories
RUN mkdir /etc/sftp/ /run/sshd/

# Create "/etc/skel/" directory
RUN rm -rf /etc/skel/ && mkdir /etc/skel/
COPY --chown=root:root ./config/skel/ /etc/skel/
COPY --from=build --chown=root:root /tmp/busybox/_install/bin/busybox /etc/skel/bin/busybox
COPY --from=build --chown=root:root /tmp/rsync/rsync /etc/skel/bin/rsync

# Disable MOTD
RUN sed -i 's|^\(.*pam_motd\.so.*\)$|#\1|g' /etc/pam.d/sshd

# Copy SSH config
COPY --chown=root:root ./config/ssh/ /etc/ssh/
RUN chmod 644 /etc/ssh/sshd_config

# Copy scripts
COPY --chown=root:root ./scripts/bin/ /usr/local/bin/
RUN chmod 755 /usr/local/bin/*

CMD ["/usr/local/bin/container-foreground-cmd"]
