################################################################################
#
# zfs-user (userspace only)
#
# OpenZFS userspace utilities: zpool, zfs, zed, zdb, etc.
# The kernel module is compiled statically into the kernel (CONFIG_ZFS=y),
# so this package only builds the userspace tools and libraries.
#
# Named zfs-user to avoid collision with Buildroot's upstream zfs package
# (which requires BR2_LINUX_KERNEL=y and builds kernel modules).
#
################################################################################

ZFS_USER_VERSION = 2.4.1
ZFS_USER_SOURCE = zfs-$(ZFS_USER_VERSION).tar.gz
ZFS_USER_SITE = https://github.com/openzfs/zfs/releases/download/zfs-$(ZFS_USER_VERSION)
ZFS_USER_LICENSE = CDDL
ZFS_USER_LICENSE_FILES = LICENSE
ZFS_USER_CPE_ID_VENDOR = openzfs
ZFS_USER_CPE_ID_PRODUCT = openzfs
ZFS_USER_INSTALL_STAGING = YES

ZFS_USER_DEPENDENCIES = \
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
ZFS_USER_CONF_OPTS = \
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
ZFS_USER_CONF_ENV = \
	PKG_CONFIG_PATH="$(STAGING_DIR)/usr/lib/pkgconfig:$(STAGING_DIR)/usr/share/pkgconfig"

$(eval $(autotools-package))
