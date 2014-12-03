VMware Provisioning
====

What this does
----
Create a new Linux VM in VMware from a template and modifes the hardware settings.  After that it expands the disk to fill the new hardware adjustments.  This is all orchestrated via Rundeck.
Now it must be noted here: VMWare does support Guest Customizations which should do some of the things in the POST provisioning, but not all Linux OS's are supported and the environment this was writtenin is not pathced to the proper version where it works in most that are supported.  So a set of more generic steps for a more universal deployment process is needed.

VMware's customization Matrix 
http://partnerweb.vmware.com/programs/guestOS/guest-os-customization-matrix.pdf

VMware Scripts
----
- vmware/datastoreClusterVMProvisioning.pl - originally sourcec from VirtuallyGhetto with some modifications to make an extreamly poor guess at which ESX host to use for balancing purposes.
- vmware/vmModify.pl - modfies the VM's hardware settings, CPU, RAM, Disk Size

Post Installation Scripts
----
- post/reboot_host - self explanitory
- post/resize_partition - resized the root partition
- post/resize_filesystem - expands the filesytem to the new partition size
- post/resize_volumes - exapnds LVM
- post/set_hostname - self explanatory
- post/cleanup - cleanup steps (currently remove vagrant user)

Known Bugs
----
- vmModify.pl seems be able to increase values and errors when decreasing them, which is typically what you want but it seems broken in that way.
