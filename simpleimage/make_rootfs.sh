#!/bin/sh
#
# Simple script to create a rootfs for aarch64 platforms including support
# for Kernel modules created by the rest of the scripting found in this
# module.
#
# Use this script to populate the second partition of disk images created with
# the simpleimage script of this project.
#

set -e

BUILD="../build"
DEST="$1"
LINUX="$2"
PACKAGEDEB="$3"
DISTRO="$4"
BOOT="$5"
MODEL="$6"
VARIANT="$7"

if [ -z "$MODEL" ]; then
  MODEL="pine64"
fi

if [ -z "$DEST" -o -z "$LINUX" ]; then
	echo "Usage: $0 <destination-folder> <linux-folder> <package.deb> [distro] [<boot-folder>] [model] [variant: mate, i3 or empty]"
	exit 1
fi

if [ "$(id -u)" -ne "0" ]; then
	echo "This script requires root."
	exit 1
fi

DEST=$(readlink -f "$DEST")
LINUX=$(readlink -f "$LINUX")

if [ ! -d "$DEST" ]; then
	echo "Destination $DEST not found or not a directory."
	exit 1
fi

if [ "$(ls -A -Ilost+found $DEST)" ]; then
	echo "Destination $DEST is not empty. Aborting."
	exit 1
fi

if [ -z "$DISTRO" ]; then
	DISTRO="xenial"
fi

if [ -n "$BOOT" ]; then
	BOOT=$(readlink -f "$BOOT")
fi

TEMP=$(mktemp -d)
cleanup() {
	if [ -e "$DEST/proc/cmdline" ]; then
		umount "$DEST/proc"
	fi
	if [ -d "$DEST/sys/kernel" ]; then
		umount "$DEST/sys"
	fi
	if [ -d "$TEMP" ]; then
		rm -rf "$TEMP"
	fi
}
trap cleanup EXIT

ROOTFS=""
UNTAR="bsdtar -xpf"
METHOD="download"

case $DISTRO in
	arch)
		ROOTFS="http://archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
		;;
	xenial)
		ROOTFS="http://cdimage.ubuntu.com/ubuntu-base/releases/16.04.2/release/ubuntu-base-16.04.2-base-arm64.tar.gz"
		;;
	sid|jessie)
		ROOTFS="${DISTRO}-base-arm64.tar.gz"
		METHOD="debootstrap"
		;;
	*)
		echo "Unknown distribution: $DISTRO"
		exit 1
		;;
esac

deboostrap_rootfs() {
	dist="$1"
	tgz="$(readlink -f "$2")"

	[ "$TEMP" ] || exit 1
	cd $TEMP && pwd

	# this is updated very seldom, so is ok to hardcode
	debian_archive_keyring_deb='https://ftp.de.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_2014.3_all.deb'
	wget -O keyring.deb "$debian_archive_keyring_deb"
	ar -x keyring.deb && rm -f control.tar.gz debian-binary && rm -f keyring.deb
	DATA=$(ls data.tar.*) && compress=${DATA#data.tar.}

	KR=debian-archive-keyring.gpg
	bsdtar --include ./usr/share/keyrings/$KR --strip-components 4 -xvf "$DATA"
	rm -f "$DATA"

	apt-get -y install debootstrap qemu-user-static

	qemu-debootstrap --arch=arm64 --keyring=$TEMP/$KR $dist rootfs http://httpredir.debian.org/debian
	rm -f $KR

	# keeping things clean as this is copied later again
	rm -f rootfs/usr/bin/qemu-aarch64-static

	bsdtar -C $TEMP/rootfs -a -cf $tgz .
	rm -fr $TEMP/rootfs

	cd -
}

mkdir -p $BUILD
TARBALL="$BUILD/$(basename $ROOTFS)"
mkdir -p "$BUILD"
if [ ! -e "$TARBALL" ]; then
	if [ "$METHOD" = "download" ]; then
		echo "Downloading $DISTRO rootfs tarball ..."
		wget -O "$TARBALL" "$ROOTFS"
	elif [ "$METHOD" = "debootstrap" ]; then
		deboostrap_rootfs "$DISTRO" "$TARBALL"
	else
		echo "Unknown rootfs creation method"
		exit 1
	fi
fi

# Extract with BSD tar
echo -n "Extracting ... "
set -x
$UNTAR "$TARBALL" -C "$DEST"
echo "OK"

# Add qemu emulation.
cp /usr/bin/qemu-aarch64-static "$DEST/usr/bin"

# Prevent services from starting
cat > "$DEST/usr/sbin/policy-rc.d" <<EOF
#!/bin/sh
exit 101
EOF
chmod a+x "$DEST/usr/sbin/policy-rc.d"

do_chroot() {
	cmd="$@"
	chroot "$DEST" mount -t proc proc /proc || true
	chroot "$DEST" mount -t sysfs sys /sys || true
	chroot "$DEST" $cmd
	chroot "$DEST" umount /sys
	chroot "$DEST" umount /proc
}

add_debian_apt_sources() {
	local release="$1"
	local aptsrcfile="$DEST/etc/apt/sources.list"
	cat > "$aptsrcfile" <<EOF
deb http://httpredir.debian.org/debian ${release} main contrib non-free
#deb-src http://httpredir.debian.org/debian ${release} main contrib non-free
EOF
	# No separate security or updates repo for unstable/sid
	[ "$release" = "sid" ] || cat >> "$aptsrcfile" <<EOF
deb http://httpredir.debian.org/debian ${release}-updates main contrib non-free
#deb-src http://httpredir.debian.org/debian ${release}-updates main contrib non-free

deb http://security.debian.org/ ${release}/updates main contrib non-free
#deb-src http://security.debian.org/ ${release}/updates main contrib non-free
EOF
}

add_pine64_apt_sources() {
	local release="$1"
	cat > "$DEST/etc/apt/sources.list" <<EOF
deb http://ports.ubuntu.com/ ${release} main restricted universe multiverse
deb-src http://ports.ubuntu.com/ ${release} main restricted universe multiverse

deb http://ports.ubuntu.com/ ${release}-updates main restricted universe multiverse
deb-src http://ports.ubuntu.com/ ${release}-updates main restricted universe multiverse

deb http://ports.ubuntu.com/ ${release}-security main restricted universe multiverse
deb-src http://ports.ubuntu.com/ ${release}-security main restricted universe multiverse

#deb http://ports.ubuntu.com/ ${release}-backports main restricted universe multiverse
#deb-src http://ports.ubuntu.com/ ${release}-backports main restricted universe multiverse
EOF
}

add_asound_state() {
	mkdir -p "$DEST/var/lib/alsa"
	cp -vf ../blobs/asound.state.$MODEL "$DEST/var/lib/alsa/asound.state"
}

# Run stuff in new system.
case $DISTRO in
	arch)
		echo "No longer supported"
		exit 1
		;;
	xenial|sid|jessie)
		rm "$DEST/etc/resolv.conf"
		cp /etc/resolv.conf "$DEST/etc/resolv.conf"
		if [ "$DISTRO" = "xenial" ]; then
			DEB=pine64
			DEBUSER=pine64
			DEBUSERPW=pine64
			EXTRADEBS="software-properties-common zram-config ubuntu-minimal nano"
			ADDPPACMD="apt-add-repository -y ppa:longsleep/ubuntu-pine64-flavour-makers"
			DISPTOOLCMD="apt-get -y install sunxi-disp-tool"
		elif [ "$DISTRO" = "sid" -o "$DISTRO" = "jessie" ]; then
			DEB=debian
			DEBUSER=debian
			DEBUSERPW=debian
			EXTRADEBS="sudo"
			ADDPPACMD=
			DISPTOOLCMD=
		else
			echo "Unknown DISTRO=$DISTRO"
			exit 2
		fi
		add_${DEB}_apt_sources $DISTRO
		cat > "$DEST/second-phase" <<EOF
#!/bin/sh
export DEBIAN_FRONTEND=noninteractive
locale-gen en_US.UTF-8
apt-get -y update
apt-get -y install dosfstools curl xz-utils iw rfkill wpasupplicant openssh-server alsa-utils jq $EXTRADEBS
apt-get -y remove --purge ureadahead
$ADDPPACMD
apt-get -y update
$DISPTOOLCMD
adduser --gecos $DEBUSER --disabled-login $DEBUSER --uid 1000
chown -R 1000:1000 /home/$DEBUSER
echo "$DEBUSER:$DEBUSERPW" | chpasswd
usermod -a -G sudo,adm,input,video,plugdev $DEBUSER
apt-get -y autoremove
apt-get clean
EOF
		chmod +x "$DEST/second-phase"
		do_chroot /second-phase
		cat > "$DEST/etc/network/interfaces.d/eth0" <<EOF
auto eth0
iface eth0 inet dhcp
EOF
		cat > "$DEST/etc/hostname" <<EOF
$MODEL
EOF
		cat > "$DEST/etc/pine64_model" <<EOF
$MODEL
EOF
		cat > "$DEST/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $MODEL

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
		cp $PACKAGEDEB $DEST/package.deb
		do_chroot dpkg -i "package.deb"
		do_chroot rm "package.deb"
		case "$VARIANT" in
			mate)
				do_chroot /usr/local/sbin/install_mate_desktop.sh
				do_chroot systemctl set-default graphical.target
				do_chroot /usr/loca/sbin/pinebook_preinstall_apps.sh
				;;
			
			i3)
				do_chroot /usr/local/sbin/install_i3_desktop.sh
				do_chroot systemctl set-default graphical.target
				;;
		esac
		do_chroot systemctl enable ssh-keygen
		if [ "$MODEL" = "pinebook" ]; then
			do_chroot systemctl enable pinebook-headphones
		fi
		sed -i 's|After=rc.local.service|#\0|;' "$DEST/lib/systemd/system/serial-getty@.service"
		rm -f "$DEST/second-phase"
		rm -f "$DEST/etc/resolv.conf"
		rm -f "$DEST"/etc/ssh/ssh_host_*
		rm -f "$DEST/usr/local/sbin/pinebook_preinstall_apps.sh"
		do_chroot ln -s /run/resolvconf/resolv.conf /etc/resolv.conf
		do_chroot apt-get -y autoremove
		do_chroot apt-get clean
		;;
	*)
		;;
esac

# Bring back folders
mkdir -p "$DEST/lib"
mkdir -p "$DEST/usr"

# Create fstab
cat <<EOF > "$DEST/etc/fstab"
# <file system>	<dir>	<type>	<options>			<dump>	<pass>
/dev/mmcblk0p1	/boot	vfat	defaults			0		2
/dev/mmcblk0p2	/	ext4	defaults,noatime		0		1
EOF

if [ -d "$LINUX" ]; then
	mkdir "$DEST/lib/modules"
	# Install Kernel modules
	make -C $LINUX ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_install INSTALL_MOD_PATH="$DEST"
	# Install Kernel firmware
	make -C $LINUX ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- firmware_install INSTALL_MOD_PATH="$DEST"
	# Install Kernel headers
	make -C $LINUX ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- headers_install INSTALL_HDR_PATH="$DEST/usr"

	# Install extra mali module if found in Kernel tree.
	if [ -e $LINUX/modules/gpu/mali400/kernel_mode/driver/src/devicedrv/mali/mali.ko ]; then
		v=$(ls $DEST/lib/modules/)
		mkdir "$DEST/lib/modules/$v/kernel/extramodules"
		cp -v $LINUX/modules/gpu/mali400/kernel_mode/driver/src/devicedrv/mali/mali.ko $DEST/lib/modules/$v/kernel/extramodules
		depmod -b $DEST $v
	fi
else
	# Install Kernel modules from tarball
	mkdir $TEMP/kernel
	tar -C $TEMP/kernel --numeric-owner -xJf "$LINUX"
	if [ -n "$BOOT" -a -e "$BOOT/uEnv.txt" ]; then
		# Install Kernel and uEnv.txt too.
		echo "Installing Kernel to boot $BOOT ..."
		rm -rf "$BOOT/pine64"
		rm -f "$BOOT/uEnv.txt"
		cp -RLp $TEMP/kernel/boot/* "$BOOT/"
		mv "$BOOT/uEnv.txt.in" "$BOOT/uEnv.txt"
	fi
	cp -RLp $TEMP/kernel/lib/* "$DEST/lib/" 2>/dev/null || true
	cp -RLp $TEMP/kernel/usr/* "$DEST/usr/"

	VERSION=""
	if [ -e "$TEMP/kernel/boot/Image.version" ]; then
		VERSION=$(cat $TEMP/kernel/boot/Image.version)
	fi

	if [ -n "$VERSION" ]; then
		# Create symlink to headers if not there.
		if [ ! -e "$DEST/lib/modules/$VERSION/build" ]; then
			ln -s /usr/src/linux-headers-$VERSION "$DEST/lib/modules/$VERSION/build"
		fi

		depmod -b $DEST $VERSION
	fi
fi

# Clean up
rm -f "$DEST/usr/bin/qemu-aarch64-static"
rm -f "$DEST/usr/sbin/policy-rc.d"

echo "Done - installed rootfs to $DEST"
