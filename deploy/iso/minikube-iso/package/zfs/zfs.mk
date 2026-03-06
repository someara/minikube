################################################################################
#
# zfs (userspace only)
#
# OpenZFS userspace utilities: zpool, zfs, zed, zdb, etc.
# The kernel module is compiled statically into the kernel (CONFIG_ZFS=y),
# so this package only builds the userspace tools and libraries.
#
################################################################################

ZFS_VERSION = 2.4.1
ZFS_SOURCE = zfs-$(ZFS_VERSION).tar.gz
ZFS_SITE = https://github.com/openzfs/zfs/releases/download/zfs-$(ZFS_VERSION)
ZFS_LICENSE = CDDL
ZFS_LICENSE_FILES = LICENSE
ZFS_CPE_ID_VENDOR = openzfs
ZFS_CPE_ID_PRODUCT = openzfs
ZFS_INSTALL_STAGING = YES

ZFS_DEPENDENCIES = \
	host-pkgconf \
	util-linux \
	zlib \
	libtirpc \
	openssl

# --with-config=user: build ONLY userspace (no kernel modules)
# --disable-static: shared libs only (smaller rootfs)
# --disable-pyzfs: skip Python bindings (not needed in minikube)
# --disable-sysvinit: systemd only, no sysvinit scripts
# --with-udevdir: udev rules location
# --with-systemdunitdir / --with-systemdpresetdir: systemd unit locations
ZFS_CONF_OPTS = \
	--with-config=user \
	--disable-static \
	--disable-pyzfs \
	--disable-sysvinit \
	--with-tirpc \
	--with-udevdir=/usr/lib/udev \
	--with-systemdunitdir=/usr/lib/systemd/system \
	--with-systemdpresetdir=/usr/lib/systemd/system-preset \
	--with-systemdgeneratordir=/usr/lib/systemd/system-generators \
	--with-dracutdir=no \
	--with-mounthelperdir=/usr/sbin

# ZFS configure needs to find libuuid and libblkid via pkg-config
ZFS_CONF_ENV = \
	PKG_CONFIG_PATH="$(STAGING_DIR)/usr/lib/pkgconfig:$(STAGING_DIR)/usr/share/pkgconfig"

$(eval $(autotools-package))
