#!/usr/bin/perl -w
# Copyright (c) 2009-2012 William Lam All rights reserved.

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 3. The name of the author or contributors may not be used to endorse or
#    promote products derived from this software without specific prior
#    written permission.
# 4. Consent from original author prior to redistribution

# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

# William Lam
# http://www.virtuallyghetto.com/

use strict;
use warnings;
use VMware::VIRuntime;
use VMware::VILib;
use Data::Dumper;
use List::Util qw(min max);
use Statistics::Basic qw(median);
use YAML::XS qw(LoadFile);

my $config = LoadFile("/opt/ops/etc/imaging.yml");

my %opts = (
   vmname => {
      type => "=s",
      help => "Name of the new VM to create from a template",
      required => 1,
   },
   datacenter => {
      type => "=s",
      help => "Datacenter to provision the machine into",
      required => 0,
   },
   environment => {
      type => "=s",
      help => "Which environment to use",
      required => 1,
   },
   stack => {
      type => "=s",
      help => "Name of host template", 
      required => 1,
   },
   vmfolder => {
      type => "=s",
      help => "Name of vCenter VM folder",
      required => 1,
   },
   division => {
      type => "=s",
      help => "What division because we can't keep things simple",
      required => 1,
   }
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate();
Util::connect();

my $stack = Opts::get_option('stack');
my $environment = Opts::get_option('environment');
my $clonename = Opts::get_option('vmname');
my $vmfolder = Opts::get_option('vmfolder');
my $division = Opts::get_option('division');

my $host_cluster = get_host_cluster($environment,$division,$config);
my $vlan = get_vlan($environment,$division,$config);
my $cluster_view = get_compute_cluster($host_cluster);
my $recommended_server = get_recommended_cluster_server($cluster_view);
my $datastore_regex = get_datastore_regex($environment,$division,$config);
my $datastore_cluster = get_datastores_objects($datastore_regex,$recommended_server);


my $datastorecluster= $datastore_cluster->[0]->name;

printf "Host Cluster: %s\n", $host_cluster;
printf "Server: %s\n", $recommended_server;
printf "Datastore Cluster: %s\n", $datastore_cluster->[0]->name;
printf "VLAN: %s\n", $vlan;

# get VM view
my $vm = get_vm($stack);
unless($vm) {
    print "Unable to locate VM: $stack!\n";
    Util::disconnect();
    exit 1;
}

# get datastore cluster view
my $dscluster = Vim::find_entity_view(view_type => 'StoragePod', filter => {'name' => $datastorecluster}, properties => ['name']);

unless($dscluster) {
    print "Unable to locate datastore cluster: $dscluster!\n";
    Util::disconnect();
    exit 1;
}

# get VM Folder view
my $folder = Vim::find_entity_view(view_type => 'Folder', filter => {'name' => $vmfolder}, properties => ['name']);
unless($folder) {
    print "Unable to locate VM folder: $vmfolder!\n";
    Util::disconnect();
    exit 1;
}

# get storage rsc mgr
my $storageMgr = Vim::get_view(mo_ref => Vim::get_service_content()->storageResourceManager);

# create storage spec
my $podSpec = StorageDrsPodSelectionSpec->new(storagePod => $dscluster);

my $clusterView = Vim::find_entity_view(view_type => 'ClusterComputeResource', filter => {'name' => qr/^$host_cluster/i });

my $host = Vim::find_entity_view ( view_type => 'HostSystem', filter => { 'name' => $recommended_server } );
my $location = VirtualMachineRelocateSpec->new(pool => $clusterView->resourcePool, host => $host);

my $cloneSpec = VirtualMachineCloneSpec->new(powerOn => 'false', template => 'false', location => $location);
my $storageSpec = StoragePlacementSpec->new(type => 'clone', cloneName => $clonename, folder => $folder, podSelectionSpec => $podSpec, vm => $vm, cloneSpec => $cloneSpec);

eval {
    my ($result,$key,$task,$msg);
    $result = $storageMgr->RecommendDatastores(storageSpec => $storageSpec);

    #reetrieve SDRS recommendation 
    $key = eval {$result->recommendations->[0]->key} || [];

    #if key exists, we have a recommendation and need to apply it
    if($key) {
        print "Cloning \"$stack\" to \"$clonename\" onto \"$datastorecluster\"\n";
        $task = $storageMgr->ApplyStorageDrsRecommendation_Task(key => [$key]);
        $msg = "\tSuccesfully cloned VM!";
        &getStatus($task,$msg);
     } else {
         print Dumper($result);
         print "Uh oh ... something went terribly wrong and we did not get back SDRS recommendation!\n";
     }
};
if($@) {
    print "Error: " . $@ . "\n";
}

Util::disconnect();

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
        sleep 2;
        $task_view->ViewBase::update_view_data();
    }
}

sub delete_unhealthy_hosts {
    my $cluster = shift;

    # clean out bad hosts   
    foreach my $hostname (keys %$cluster) {
        # remove unhealthy nodes
        if ($cluster->{$hostname}->{health} ne "green") {
            delete $cluster->{$hostname};
            next; 
        }

        # cannot make an accurate decision on unknown values
        if (!$cluster->{$hostname}->{cpu_usage}) {
            delete $cluster->{$hostname};
            next; 
        }

        if (!$cluster->{$hostname}->{memory_usage}) {
            delete $cluster->{$hostname};
            next; 
        }
    }
}

sub recommend_a_host {
    # There is a flaw here .. treating everything as though they have
    # ths same amount of memory or cpu.. they do NOT.
    # In theory this will not be a problem because we are chekcking against
    # the overall status which should return a painful color when bad but still
    # this is really just crap... not a lot of thought went into this 
    # we will revisit this again later (hopefully for real node clusters?)

    my $cluster = shift;
    die "no host could be recommended, exiting!" if keys %$cluster < 1;

    my @cpu;
    my @memory;
 
    foreach my $host (keys %$cluster) {
        push @cpu, $cluster->{$host}->{cpu_usage};
        push @memory, $cluster->{$host}->{memory_usage};
    } 

    my $min_cpu = min @cpu; 
    my $min_mem = min @memory;
    my $median_cpu = int(median @cpu);
    my $median_mem = int(median @memory);
    my $host_by_cpu;
    my $host_by_mem;

    foreach my $h (keys %$cluster) {
        if ($cluster->{$h}->{cpu_usage} == $min_cpu) {
            $host_by_cpu = $h;
        }

        if ($cluster->{$h}->{memory_usage} == $min_mem) {
            $host_by_mem = $h;
        }
    }

    # if min cpu and mem match, this is our host
    if ($host_by_mem eq $host_by_cpu) {
        $host_by_mem;
    }elsif ($cluster->{$host_by_mem} < $median_mem) {
        return $host_by_mem; 
    }elsif ($cluster->{$host_by_cpu} < $median_cpu) {
        return $host_by_cpu; 
    }else {
        return $host_by_mem; 
    }
}

sub get_datastores_objects {
    my ($name_filter,$server_name) = @_;
    my @split_name = split(/\-/,$server_name);
    my $pod_number = $split_name[1];

    my $dsc = Vim::find_entity_views (
        view_type => 'StoragePod',
        filter => { name => qr/$name_filter/ },
        properties => ['name']
    );
    foreach my $ds (@$dsc) {
        if ($ds->name =~ /$pod_number/) {
            return [$ds];
        }
    } 
    die "Failed to retrieve a datastore cluster, exiting!";
}

sub get_compute_cluster {
    my $cluster = shift;

    my $cc_entity = Vim::find_entity_view (
        view_type => 'ClusterComputeResource',
        filter => { 'name' => qr/^$cluster/i }
    );
    return $cc_entity;
}

sub get_host_systems {
    my $cluster_view = shift;

    my $hs_entity = Vim::find_entity_views( view_type => 'HostSystem',
        begin_entity => $cluster_view,
        properties => [ 'summary', 'datastore' ]
    );
    return $hs_entity;
}

sub get_vm {
    my $stack_name = shift;

    my $vm_entity = Vim::find_entity_view(
        view_type => 'VirtualMachine',
        filter => {'name' => $stack_name}, properties => ['name']
    );
    return $vm_entity;
}

sub get_datastore_regex {
    my ($env,$div,$conf) = @_;

    if ( exists $conf->{divisions}->{$div}->{environments}->{$env} ) {
        return $conf->{divisions}->{$div}->{environments}->{$env}->{datastore_clusters};
    }elsif( exists $conf->{divisions}->{$div}->{environments}->{default} ) {
        return $conf->{divisions}->{$div}->{environments}->{default}->{datastore_clusters};
    }else{
        die "No datastore_cluster are set in the configuration file.  exiting!"
    } 
}

sub get_vlan {
    my ($env,$div,$conf) = @_;

    if ( exists $conf->{divisions}->{$div}->{environments}->{$env} ) {
        return $conf->{divisions}->{$div}->{environments}->{$env}->{vlans}->{default};
    }elsif( exists $conf->{divisions}->{$div}->{environments}->{default} ) {
        return $conf->{divisions}->{$div}->{environments}->{default}->{vlans}->{$env};
    }else{
        die "No vlans are set in the configuration file.  exiting!"
    }
}

sub get_host_cluster {
    my ($env,$div,$conf) = @_;

    if ( exists $conf->{divisions}->{$div}->{environments}->{default} ) {
        my $div_as_env = $conf->{divisions}->{$div}->{environments}->{default}->{host_clusters};
        return $div_as_env->[rand @$div_as_env];
    }elsif( exists $conf->{divisions}->{$div}->{environments}->{$env} ) {
        my $env_as_env = $conf->{divisions}->{$div}->{environments}->{$env}->{host_clusters};
        return $env_as_env->[rand @$env_as_env];
    }else{
        die "No host cluster defined in configuration file.  exiting!"
    } 
}

sub get_recommended_cluster_server {
    my $view = shift;

    my $hosts = get_host_systems($view);
    my %cluster_info;

    foreach my $vm_ref (@$hosts) {
        # gray (uknown), green (ok), red(problem), yellow(possible problem)
        $cluster_info{$vm_ref->summary->config->name}{health} = $vm_ref->summary->overallStatus->val;
        # cpu usage in megahertz
        $cluster_info{$vm_ref->summary->config->name}{cpu_usage} = $vm_ref->summary->quickStats->overallCpuUsage;
        # memory usage in MB
        $cluster_info{$vm_ref->summary->config->name}{memory_usage} = $vm_ref->summary->quickStats->overallMemoryUsage;
    }

    delete_unhealthy_hosts(\%cluster_info);
    my $host = recommend_a_host(\%cluster_info);
    return $host;
}

=head1 NAME

datastoreClusterVMProvisioning.pl - Script to clone VMs onto datastore cluster in vSphere 5

=head1 Examples

=over 4

=item List available datastore clusters

=item

./datastoreClusterVMProvisioning.pl --server [VCENTER_SERVER] --username [USERNAME] --vmname [VM_TO_CLONE] --clonename [NAME_OF_NEW_VM] --vmfolder [VM_FOLDER] --datastorecluster [DATASTORE_CLUSTER] 

=item

=back

=head1 SUPPORT

vSphere 5.0

=head1 AUTHORS

William Lam, http://www.virtuallyghetto.com/

=cut
