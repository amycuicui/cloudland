#!/bin/bash

cd $(dirname $0)
source ../cloudrc

[ $# -lt 5 ] && die "$0 <vm_ID> <cpu> <memory> <disk_size> <hostname>"

ID=$1
vm_ID=inst-$1
vm_cpu=$2
vm_mem=$3
disk_size=$4
role=${5%%-*}
vm_stat=error
vm_vnc=""

vm_disk=$image_dir/$vm_ID.disk
rm -f $vm_disk
qemu-img create $vm_disk -f qcow2 "${disk_size}G"
kernel=rhcos-installer-kernel
ramdisk=rhcos-installer-initramfs.img
if [ ! -f "$image_cache/$kernel" ]; then
    wget -q $image_repo/$kernel -O $image_cache/$kernel
fi
if [ ! -f "$image_cache/$ramdisk" ]; then
    wget -q $image_repo/$ramdisk -O $image_cache/$ramdisk
fi
metadata=$(cat)
[ -z "$vm_mem" ] && vm_mem='1024m'
[ -z "$vm_cpu" ] && vm_cpu=1
let vm_mem=${vm_mem%[m|M]}*1024
mkdir -p $xml_dir/$vm_ID
vm_xml=$xml_dir/$vm_ID/$vm_ID.xml
template=$template_dir/openshift.xml
cp $template $vm_xml
sed -i "s/VM_ID/$vm_ID/g; s/VM_MEM/$vm_mem/g; s/VM_CPU/$vm_cpu/g; s#VM_IMG#$vm_disk#g; s/ROLE_IGN/${role}.ign/g;" $vm_xml
state=error
virsh define $vm_xml
vlans=$(jq .vlans <<< $metadata)
nvlan=$(jq length <<< $vlans)
i=0
while [ $i -lt $nvlan ]; do
    vlan=$(jq -r .[$i].vlan <<< $vlans)
    ip=$(jq -r .[$i].ip_address <<< $vlans)
    mac=$(jq -r .[$i].mac_address <<< $vlans)
    jq .security <<< $metadata | ./attach_nic.sh $ID $vlan $ip $mac 
    let i=$i+1
done
virsh start $vm_ID
count=0
while [ $count -le 100 ]; do
    sleep 5
    virsh list | grep $vm_ID
    [ $? -ne 0 ] && break
    let count=$count+1
done
if [ $? -eq 0 ]; then
    virsh dumpxml $vm_ID 2>/dev/null > ${vm_xml}.dump
    mv -f ${vm_xml}.dump $vm_xml
    virsh undefine $vm_ID
    sed -i "/initrd/d;/kernel/d;/cmdline/d;s/<on_reboot>destroy/<on_reboot>restart/;s/<on_crash>destroy/<on_crash>restart/" ${vm_xml}
    virsh define $vm_xml
    virsh start $vm_ID
    [ $? -eq 0 ] && state=running && ./replace_vnc_passwd.sh $ID
    virsh autostart $vm_ID
fi
echo "|:-COMMAND-:| launch_vm.sh '$ID' '$state' '$SCI_CLIENT_ID' 'unknown'"
