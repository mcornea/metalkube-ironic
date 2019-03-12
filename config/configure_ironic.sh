#!/bin/bash


# Configure dnsmasq and pxe boot parameters.

IRONIC_IP="${IRONIC_IP}:-172.22.0.1"
IRONIC_DHCP_RANGE="${IRONIC_DHCP_RANGE}:-172.22.0.10,172.22.0.100"

cat dnsmasq.conf | sed -e s/IRONIC_IP/$IRONIC_IP/g -e s/IRONIC_DHCP_RANGE/$IRONIC_DHCP_RANGE/g > /etc/dnsmasq.conf
cat dualboot.ipxe | sed s/IRONIC_IP/$IRONIC_IP/g > /var/www/html/dualboot.ipxe
cat inspector.ipxe | sed s/IRONIC_IP/$IRONIC_IP/g/ > /var/www/html/inspector.ipxe

# Add firewall rules to ensure the IPA ramdisk can reach Ironic and Inspector APIs on the host
for port in 5050 6385 ; do
    if ! sudo iptables -C INPUT -i provisioning -p tcp -m tcp --dport $port -j ACCEPT > /dev/null 2>&1; then
        sudo iptables -I INPUT -i provisioning -p tcp -m tcp --dport $port -j ACCEPT
    fi
done

# Get the images we need to serve.
mkdir -p /var/www/html/images
pushd /var/www/html/images

export RHCOS_IMAGE_URL=${RHCOS_IMAGE_URL:-"https://releases-rhcos.svc.ci.openshift.org/storage/releases/maipo/"}
export RHCOS_IMAGE_VERSION="${RHCOS_IMAGE_VERSION:-47.284}"
export RHCOS_IMAGE_NAME="redhat-coreos-maipo-${RHCOS_IMAGE_VERSION}"
export RHCOS_IMAGE_FILENAME="${RHCOS_IMAGE_NAME}-qemu.qcow2"
export RHCOS_IMAGE_FILENAME_OPENSTACK="${RHCOS_IMAGE_NAME}-openstack.qcow2"
export RHCOS_IMAGE_FILENAME_DUALDHCP="${RHCOS_IMAGE_NAME}-dualdhcp.qcow2"
export RHCOS_IMAGE_FILENAME_LATEST="redhat-coreos-maipo-latest.qcow2"

curl --insecure --compressed -L -o "${RHCOS_IMAGE_FILENAME_OPENSTACK}" "${RHCOS_IMAGE_URL}/${RHCOS_IMAGE_VERSION}/${RHCOS_IMAGE_FILENAME_OPENSTACK}".gz
curl --insecure --compressed -L https://images.rdoproject.org/master/rdo_trunk/current-tripleo/ironic-python-agent.tar | tar -xf -

# Workaround so that the dracut network module does dhcp on eth0 & eth1
RHCOS_IMAGE_FILENAME_RAW="${RHCOS_IMAGE_FILENAME_OPENSTACK}.raw"
if [ ! -e "$RHCOS_IMAGE_FILENAME_DUALDHCP" ] ; then
    # Calculate the disksize required for the partitions on the image
    # we do this to reduce the disk size so that ironic doesn't have to write as
    # much data during deploy, as the default upstream disk image is way bigger
    # then it needs to be. Were are adding the partition sizes and multiplying by 1.2.
    DISKSIZE=$(virt-filesystems -a "$RHCOS_IMAGE_FILENAME_OPENSTACK" -l | grep /dev/ | awk '{s+=$5} END {print s*1.2}')
    truncate --size $DISKSIZE "${RHCOS_IMAGE_FILENAME_RAW}"
    virt-resize --no-extra-partition "${RHCOS_IMAGE_FILENAME_OPENSTACK}" "${RHCOS_IMAGE_FILENAME_RAW}"

    LOOPBACK=$(sudo losetup --show -f "${RHCOS_IMAGE_FILENAME_RAW}" | cut -f 3 -d /)
    mkdir -p /tmp/mnt
    sudo kpartx -a /dev/$LOOPBACK
    sudo mount /dev/mapper/${LOOPBACK}p1 /tmp/mnt
    sudo sed -i -e 's/ip=eth0:dhcp/ip=eth0:dhcp ip=eth1:dhcp/g' /tmp/mnt/grub2/grub.cfg 
    sudo umount /tmp/mnt
    sudo kpartx -d /dev/${LOOPBACK}
    sudo losetup -d /dev/${LOOPBACK}
    qemu-img convert -O qcow2 -c "$RHCOS_IMAGE_FILENAME_RAW" "$RHCOS_IMAGE_FILENAME_DUALDHCP"
    rm "$RHCOS_IMAGE_FILENAME_RAW"
fi

if [ ! -e "$RHCOS_IMAGE_FILENAME_DUALDHCP.md5sum" -o \
     "$RHCOS_IMAGE_FILENAME_DUALDHCP" -nt "$RHCOS_IMAGE_FILENAME_DUALDHCP.md5sum" ] ; then
    md5sum "$RHCOS_IMAGE_FILENAME_DUALDHCP" | cut -f 1 -d " " > "$RHCOS_IMAGE_FILENAME_DUALDHCP.md5sum"
fi

ln -sf "$RHCOS_IMAGE_FILENAME_DUALDHCP" "$RHCOS_IMAGE_FILENAME_LATEST"
ln -sf "$RHCOS_IMAGE_FILENAME_DUALDHCP.md5sum" "$RHCOS_IMAGE_FILENAME_LATEST.md5sum"
popd

