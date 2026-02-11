################################################################################
#
# zfs
#
################################################################################

ZFS_VERSION = 2.4.0
ZFS_SITE = https://github.com/openzfs/zfs/releases/download/zfs-$(ZFS_VERSION)
ZFS_SOURCE = zfs-$(ZFS_VERSION).tar.gz
ZFS_LICENSE = CDDL-1.0
ZFS_LICENSE_FILES = LICENSE
ZFS_CPE_ID_VENDOR = openzfs
ZFS_CPE_ID_PRODUCT = openzfs

ZFS_DEPENDENCIES = \
	host-pkgconf \
	libtirpc \
	util-linux \
	zlib \
	openssl \
	udev

# ZFS needs the kernel to be built first for module compilation
ZFS_DEPENDENCIES += linux

ZFS_CONF_OPTS = \
	--with-linux=$(LINUX_DIR) \
	--with-linux-obj=$(LINUX_DIR) \
	--with-tirpc \
	--disable-pyzfs \
	--disable-sysvinit \
	--enable-systemd \
	--with-systemdunitdir=/usr/lib/systemd/system \
	--with-systemdpresetdir=/usr/lib/systemd/system-preset \
	--with-systemdgeneratordir=/usr/lib/systemd/system-generators \
	--with-udevdir=/lib/udev \
	--with-mounthelperdir=/sbin

# Disable debug
ZFS_CONF_OPTS += --disable-debug

# Build kernel module
ZFS_CONF_OPTS += --with-config=all

# Make sure kernel headers are available
ZFS_MAKE_ENV = \
	KERNEL_SRC=$(LINUX_DIR) \
	KERNEL_OBJ=$(LINUX_DIR)

define ZFS_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(ZFS_MAKE_ENV) $(MAKE) -C $(@D)
endef

define ZFS_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(ZFS_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
	# Install kernel modules
	$(TARGET_MAKE_ENV) $(ZFS_MAKE_ENV) $(MAKE) -C $(@D)/module DESTDIR=$(TARGET_DIR) install
	# Create module load configuration
	$(INSTALL) -D -m 0644 /dev/null $(TARGET_DIR)/etc/modules-load.d/zfs.conf
	echo "zfs" > $(TARGET_DIR)/etc/modules-load.d/zfs.conf
	# Enable ZFS services
	mkdir -p $(TARGET_DIR)/etc/systemd/system/multi-user.target.wants
	ln -sf /usr/lib/systemd/system/zfs-import-cache.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/zfs-import-cache.service
	ln -sf /usr/lib/systemd/system/zfs-import.target \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/zfs-import.target
	ln -sf /usr/lib/systemd/system/zfs-mount.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/zfs-mount.service
	ln -sf /usr/lib/systemd/system/zfs.target \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/zfs.target
endef

$(eval $(autotools-package))
