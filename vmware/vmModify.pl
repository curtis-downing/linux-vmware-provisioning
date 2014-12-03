#!/usr/bin/perl -w

# change system hardware specs

use strict;
use warnings;
use VMware::VIRuntime;
use VMware::VILib;
use Data::Dumper;
use List::Util qw(min max);
use Statistics::Basic qw(median);

my %opts = (
   vmname => {
      type => "=s",
      help => "Name of the new VM to create from a template",
      required => 1,
   },
   disk => {
      type => "=s",
      help => "Disk size in GB",
      required => 1,
   },
   cpus => {
      type => "=s",
      help => "Number of CPUs",
      required => 1,
   },
   memory => {
      type => "=s",
      help => "Memory size in GB",
      required => 1,
   }
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate();
Util::connect();

my $vmname = Opts::get_option('vmname');
my $cpus = int(Opts::get_option('cpus'));
my $memory = int(Opts::get_option('memory'));
my $disk = int(Opts::get_option('disk'));

$memory = $memory * 1024;
$disk = $disk * 1024 * 1024;


my $vm = Vim::find_entity_view (
    view_type => 'VirtualMachine',
    filter => { name => qr/$vmname/}
);

my %existing_drive;
for my $vm_info ($vm->config) {
    my $hardware = $vm_info->hardware;
    for my $hw ($hardware->device) {
        for my $dev (@$hw) {
            my $disk_label = $dev->{deviceInfo}->{label};
            if ( "$disk_label" eq 'Hard disk 1' ) {
                $existing_drive{key} = $dev->key;
                $existing_drive{backing} = $dev->backing;
                $existing_drive{deviceInfo} = $dev->deviceInfo;
                $existing_drive{controllerKey} = $dev->controllerKey;
                $existing_drive{unitNumber} = $dev->unitNumber;
            }
        }
    }
}

my $new_drive_specs = VirtualDisk->new(
    capacityInKB => $disk,
    backing => $existing_drive{backing},
    deviceInfo => $existing_drive{deviceInfo},
    controllerKey => $existing_drive{controllerKey},
    key => $existing_drive{key},
    unitNumber => $existing_drive{unitNumber}
);

my $vmspec = VirtualMachineConfigSpec->new(
    changeVersion => $vm->config->changeVersion,
    memoryMB => $memory,
    numCPUs => $cpus,
    deviceChange => [
        VirtualDeviceConfigSpec->new(
           operation => VirtualDeviceConfigSpecOperation->new("edit"),
           device => $new_drive_specs
        )
    ]
);

eval {
        print "Reconfiguring memory for " . $vm->name . "\n";
        my $task = $vm->ReconfigVM_Task(spec => $vmspec);
        my $msg = "\tSucessfully reconfigured " . $vm->name . "\n";
        &getStatus($task,$msg);

};

if($@) {
        print "ERROR " . $@ . "\n";
}

sub getStatus {
        my ($taskRef,$message) = @_;

        my $task_view = Vim::get_view(mo_ref => $taskRef);
        my $taskinfo = $task_view->info->state->val;
        my $continue = 1;
        while ($continue) {
                my $info = $task_view->info;
                if ($info->state->val eq 'success') {
                        print $message,"\n";
                        return $info->result;
                        $continue = 0;
                } elsif ($info->state->val eq 'error') {
                        my $soap_fault = SoapFault->new;
                        $soap_fault->name($info->error->fault);
                        $soap_fault->detail($info->error->fault);
                        $soap_fault->fault_string($info->error->localizedMessage);
                        die "$soap_fault\n";
                }
                sleep 5;
                $task_view->ViewBase::update_view_data();
        }
}


Util::disconnect();
