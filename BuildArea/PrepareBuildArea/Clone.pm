=head1 NAME

BuildArea::PrepareBuildArea::Clone

=head1 SYNOPSIS

    use BuildArea::PrepareBuildArea::Clone;
    my $clonebuildarea = BuildArea::PrepareBuildArea::Clone->new({
        job         => $job,
        p4ws        => $p4ws,
        p4port      => $p4port,
        p4user      => $p4user,
        lastjob     => $lastjob,
        bootstrap_args  => $args,
    });

    my $snapshot = $clonebuildarea->perfect_snapshot($cluster, $job, $type);
    my @snapshot_and_job = $clonebuildarea->perfect_snapshot($cluster, $job, $type);
    my $snapshot = $clonebuildarea->snapshot_for($cluster, $job, $type, $anchor);
    my $branch_record = $clonebuildarea->get_branch_record($args);

    $clonebuildarea->set_source_area;
    $clonebuildarea->create_area;
    $clonebuildarea->update_area;
    $clonebuildarea->prepare_to_run_at_lkg;
    $clonebuildarea->find_last_build;
    $clonebuildarea->find_latest_pass;
    $clonebuildarea->create_clone;
    $clonebuildarea->update_perforce_client;
    $clonebuildarea->update_clone_config_area;
    $clonebuildarea->post_clone;
    $clonebuildarea->enable_sterile;


=head1 DESCRIPTION

Subclass Module to handle cloning of build area.

=head1 SEE ALSO

BuildArea::PrepareBuildArea::Basic,
batfs::clone,
BuildArea::SyncWorkspace,
MW::BranchHistory::Snap,
MW::BranchHistory::Promote

=cut

package BuildArea::PrepareBuildArea::Clone;

use strict;
use warnings;

use base qw( BuildArea::PrepareBuildArea::Basic );

use Class::Std;

use Fatal qw( :void chdir mkdir );

use batfs::clone;
use snapshot;
use ArchiveArea;

use BuildArea::SyncWorkspace qw();
use MW::BranchHistory::Snap;
use MW::BranchHistory::Promote;
use JMD::Cluster;
use JMD::Job;

use Data::Dumper;

=head1 CONSTRUCTOR

=over

=item
    BuildArea::PrepareBuildArea::Clone->new({
        job         => $job,
        p4ws        => $p4ws,
        p4port      => $p4port,
        p4user      => $p4user,
        lastjob     => $lastjob,
        bootstrap_args  => $args,
    });

Use $job as the job number.

Use $p4ws as the name of the workspace/client.

Use $p4port as the port number of Perforce Server.

Use $p4user as the username invoking perfore command.

Use $lastjob as the link to the last job (generaly link to the 'current' directory).

Use $args as the ref to arguments list to cluster_bootstrap.

=back

=head1 Constructor Arguments ACCESSOR METHODS

=over 4

=cut

=item B<< $clonebuildarea->get_clonecl >>

Change Number form where you need to clone.

=item B<< $clonebuildarea->get_lastjob >>

Last job on the cluster from where you can clone.

=item B<< $clonebuildarea->get_snap_job_id >>

Job number in Parent from where you last snapped.

=item B<< $clonebuildarea->get_skip_clone_sync_config >>

Flag to indicate if we should sync config area or not after cloning.

=item B<< $clonebuildarea->get_rebasing >>

Flag to indicate if we are rebasing from source or not.

=cut

my %clonecl_of                  : ATTR( :name<clonecl> :default<> );
my %lastjob_of                  : ATTR( :name<lastjob> :default<> );
my %snap_job_id_of              : ATTR( :name<snap_job_id> :default<> );
my %snap_job_time_of            : ATTR( :name<snap_job_time> :default<> );
my %skip_clone_sync_config_of   : ATTR( :name<skip_clone_sync_config> :default<> );
my %rebasing_of                 : ATTR( :name<rebasing> :default(0) );
my %clone_promotable_of         : ATTR( :name<clone_promotable> :default(0) );
my %clone_cluster_of            : ATTR( :name<clone_cluster> :default<> );
my %skip_clone_config_update_of : ATTR( :name<skip_clone_config_update> :default(0) );

=back

=head1 INSTANCE METHODS

=over 4

=item B<< $clonebuildarea->create_area >>

This subroutine is generally called after we have the source for cloning.

Checks if the job should be run below LKG or not and prepares it if it has to.
This returns a clone of the source.

=cut

sub create_area {
    my ($self) = @_;

    my $run_at_lkg = $self->get_job->is_lkg;

    # it's possible the stage cluster job is at an older change
    # than the area we are cloning -- abort this job if that is the case.
    if( !$self->get_allow_below_lkg
        && $self->get_jobcl < $self->get_clonecl
        && !$run_at_lkg) {

        $self->abort_job("Cannot run a job at change level ".$self->get_jobcl
                        ." earlier than where we are cloning ".$self->get_clonecl);
    }

    return $self->create_clone;

}


sub use_area {
    my ($self, $area) = @_;

    $self->revert_config_changes;

    print "Setting current dir : $area\n";
    chdir $area;

    $self->set_sbroot($area);
    $self->use_clone_client;
    return;
}

=item B<< $clonebuildarea->update_area >>

This subroutine updates the perforce client with the cloned build area and client.
Updates the config area of the clone to get the changes of config area in them.

=cut

sub update_area {
    my ($self) = @_;
    $self->update_clone_config_area;
    return;
}

=item B<< $clonebuildarea->prepare_to_run_at_lkg >>

This subroutine is used to prepare the arguments with correct change list
so it can run at LKG.

=cut

sub prepare_to_run_at_lkg {
    my ($self) = @_;

    my $args = $self->get_bootstrap_args;
    my $clonecl = $self->get_clonecl;
    my $jobcl = $self->get_jobcl;

    print "Running job at LKG $clonecl rather than job $jobcl\n";
    s/^$jobcl$/$clonecl/
        for @$args;

    $self->set_jobcl($clonecl);
    $self->set_bootstrap_args($args);
}

=item B<< $clonebuildarea->set_source_area >>

When we know of the cluster name from which to clone,
we can use this method to set the source area with snapshot path of the cluster name.

=cut

sub set_source_area {
    my ($self) = @_;

    my $clonefrom = $self->get_clonefrom;

    # If directive is 'CLONE_BUILD noreset'
    # just return the last build of the cluster.
    if ($clonefrom eq 'noreset') {
        $self->find_last_build;
        if ($self->get_source) {
            $self->set_skip_clone_config_update(1);
            return;
        }
    }

    my $source = eval {batfs::clone::snap_path($clonefrom)};

    if (!$source && $clonefrom !~ m{^/}) {
        my ($clonejob) = $clonefrom =~ /^ j? ( \d+ ) $/x;
        if ($clonejob) {
            print localtime()." Clonefrom is a job: $clonejob\n";
            $clonejob = JMD::Job->new({ job_id => $clonejob });
            $source = eval {$self->perfect_snapshot($clonejob->get_jmd_cluster,
                                                    $clonejob)};
        } else {
            $source = eval {$self->perfect_snapshot($clonefrom)};
        }
    }
    $self->abort_job("unable to find snapshot to clone from '$clonefrom': $@")
        if !$source;

    $self->set_source($source);
    print localtime()." source $source\n";

    my ($clonejob) = $source =~ m{snapshot/[^.]+\.(\d+)};
    my $jmd_job = JMD::Job->new({ job_id => $clonejob });
    my $clonecl = $jmd_job->get_p4_change_level;
    $self->set_clonecl($clonecl);
    $self->set_clone_cluster($jmd_job->get_jmd_cluster);
    print localtime()." cloning job $clonejob at change level $clonecl\n";

    # Mark clone as promotable for post commit job.
    $self->set_clone_promotable(1)
        if $self->get_job->is_post_commit;

    return;
}

=item B<< $clonebuildarea->find_last_build >>

Sets the source and clone change level using the last build of the cluster.

=cut

sub find_last_build {
    my ($self) = @_;

    my $lastjob = $self->get_lastjob;

    $self->abort_job(" Unable to determine previous job for noreset")
        if !$lastjob;

    # TODO lastjob *may* not be a valid job; e.g., it blew up in the bootstrap
    # and we really need to find the last 'running' job.  TBD how that happens.

    print "Found lastjob = $lastjob\n";
    $lastjob = JMD::Job->new({job_id => $lastjob});

    my $lastcl = $lastjob->get_p4_change_level;
    my $lastbuild = $lastjob->get_build_area;

    print "Found last build path $lastbuild\n";

    my $snapshot = $self->snapshot_for($self->get_cluster, $lastjob, undef, $lastbuild);

    if (!$snapshot) {
        $self->crash_job("Unable to access build area $lastbuild")
            if !-d $lastbuild;

        my $ssname = $self->get_cluster. ".$lastjob.noreset";
        print "Creating snapshot $ssname\n";

        my $ssobj = snapshot->new({root=>$lastbuild});
        my $ss = $ssobj->create($ssname);
        $snapshot = $ss->get_path;
    }

    my $source = $snapshot;
    $source =~ s{/build$}{};

    $self->set_source($source);
    print localtime()." source $source\n";

    $self->set_clonecl($lastcl);
    $self->set_clone_cluster($self->get_cluster);

    return;
}

=item B<< $clonebuildarea->find_latest_pass >>

Sets the source and clone change level using the last pass of the cluster.
It also checks if the parent cluster has moved on and do we have to rebase from parent?

=cut

sub find_latest_pass {
    my ($self) = @_;

    # Get the latest pass job info
    my ($pass_snapshot, $latest_pass_job) = $self->perfect_snapshot($self->get_cluster);

    my $latest_pass_cl = $latest_pass_job->get_p4_change_level;

    my $stream = $self->get_p4->FetchClient->_Stream;
    my $branch_name = $self->depot_branch_of($stream);

    my $branch_record = $self->get_branch_record({
                        action  => 'Snap',
                        branch  => $branch_name,
                        p4      => $self->get_p4,
                        path    => $pass_snapshot,
                        depot_path => $stream,
                        required_record => 'job',
                        identifier => '@'.$latest_pass_cl});

    # last passed snap job id
    my $pass_snap_time = $branch_record->{time};

    #TODO
    # if pass_snapshot is on a different filer than the cluster is *now*,
    # it should not do an incremental
    if ($pass_snap_time eq $self->get_snap_job_time) {
        # Last snap job has not changed; reclone the old build area
        print "Last SNAP job has not changed - cloning $pass_snapshot\n";
        print "cloning own job $latest_pass_job with have table at change level $latest_pass_cl\n";
        $self->set_source($pass_snapshot);
        $self->set_clonecl($latest_pass_cl);
        $self->set_clone_cluster($self->get_cluster);
        # Mark clone as promotable for incremental Job.
        $self->set_clone_promotable(1);
    } else {
        print "Rebasing from parent: last SNAP job has changed\n";
        $self->set_rebasing(1);
    }

    return;
}

=item B<< $clonebuildarea->create_clone >>

Creates the clone using batfs::clone and sets the correct sandbox root.

=cut

sub create_clone {
    my ($self) = @_;

    my $source = $self->get_source;
    my $cluster = $self->get_cluster;
    my $jobid = $self->get_job;
    my $sbroot = $self->get_sbroot;
    my $foreign = $self->get_cloneargs->{foreign};

    # when debugging, allow the same invocation to be run over and over
    # by making a different name each run
    my $ext;
    $ext = $$
        if $self->get_debug;

    #TODO *only* pass $sbroot (dest filer) if we are HS doing a rebase
    print localtime()." cloning $source\n";
    my $clone = eval {batfs::clone::make_clone($source, "$cluster.$jobid", $sbroot, $ext, $foreign)};

    $self->crash_job("ERROR during making clone of $source: $@")
        if $@;

    print localtime()." Created build clone $clone\n";

    print "Setting current dir : $clone\n";
    chdir $clone;

    mkdir ".before.$jobid";
    for my $file (grep !/^build$/, <*>) {
        rename $file, ".before.$jobid/$file";
    }

    $sbroot = "$clone/build";

    # Mark the clone as promotable
    batfs::clone::mark_clone_to_promote($sbroot)
        if $self->get_clone_promotable;

    print localtime()." Cloning finished\n";

    return $sbroot;
}

=item B<< $clonebuildarea->update_clone_config_area >>

Updates the config area of the clone with config changes after reverting
and syncing the config area.
It also calls to perform the bybrid snap activities before processing config
changes.
This prevents a lot of build churn for big clusters.

=cut

sub update_clone_config_area {
    my ($self) = @_;

    return
        if $self->get_skip_clone_config_update;

    eval { $self->ensure_stream("CloneBuild"); };

    $self->crash_job("ERROR during ensuring stream for clonebuild client: $@")
        if $@;

    # Prepare build area updates the value of p4ws, clonefrom and sbroot.
    my $p4ws = $self->get_p4ws;
    my $p4 = $self->get_p4;
    my $sbroot = $self->get_sbroot;

    # Update the config area in the clone

    # Update the clone to match the cloned-from change level;
    # this should always happen when on the same branch.

    my $synccl = $self->get_clone_base_change;
    if (defined $synccl) {
        my $sb = "//$p4ws/...";
        my $atsynccl = length $synccl ? '@'.$synccl : '';

        print localtime()." Initializing clone have-table to $sb$atsynccl\n";
        my @res = BuildArea::SyncWorkspace::run_sync($p4, ['-k'], "$sb$atsynccl");
    }

    if (!$self->get_skip_clone_sync_config) {
        print localtime()." Force the update of the clone config\n";
        $self->sync_config('-f');
    }

    print localtime()." Post clone processing\n";
    $self->post_clone;

    print localtime()." Processing all config changes on clone\n";
    eval { $self->process_config_changes };

    $self->abort_job("ERROR during processing config changes on clone: $@")
        if $@;
}

sub get_clone_base_change {
    my ($self) = @_;

    # If we do not want to update the clone client,
    # sync to the job cl so that PWS does nothing.
    # (e.g,. for analysis clusters).

    my $synccl = $self->get_skip_clone_sync_config
                 ? $self->get_jobcl
                 : $self->get_clonecl;
    return $synccl;
}

=item B<< $clonebuildarea->post_clone >>

Relatively simple routine as for simple cloning you need not do all the activites for Hybrid Snap.

=cut

sub rebase_token_file {
    my ($self) = @_;
    return '.rebase-snap';
}

sub post_clone {
    my ($self) = @_;

    # only do the unlink if the file already exists;
    # this is only to avoid an unexplained SEGV when this isn't conditional
    # (!!)
    my $rebase_file = $self->rebase_token_file;
    unlink $rebase_file
        if -f $rebase_file;

    # Updating have table to mwfixes changes if needed.
    # This update will happen for 'clone based' qual and acceptance jobs
    # Please check the following wiki,
    # http://inside.mathworks.com/wiki/Chaser_Workflow_changes_for_Bootstrap_and_PWS
    # If clonejob is mwfixes job then move the have table forward.
    my $clone_change_level = $self->get_clone_job_change_level;

    if ($clone_change_level->get_fixes_changelevel) {
        $self->update_have_to_mwfixes_changes($clone_change_level);
    }
    return;
}

sub update_have_to_mwfixes_changes {
    my ($self, $change_level) = @_;

    return
        if $self->get_skip_clone_sync_config;

    my $p4ws = $self->get_p4ws;
    my $p4 = $self->get_p4;
    my $mw_fixes_path = $change_level->get_fixes_path;
    my $mw_fixes_change_level = $change_level->get_fixes_changelevel;

    print localtime()." Clone job is based of a mwfixes stream.\n";

    my $client_stream = $p4->FetchClient->_Stream;
    # 1. switch the client to use the //mwfixes stream
    print localtime()." Switching $p4ws to $mw_fixes_path\n";
    $p4->fmsg("Unable to alter client $p4ws")
        ->RunClient('-s', '-S', $mw_fixes_path, $p4ws);

    # 2. p4 sync -k @FixesLKG
    print localtime()." Syncing now to the fixes changelevel: $mw_fixes_change_level \n";
    my @sync_result = $p4->fmsg("Unable to run sync on clone after
                    switching to mwfixes branch $mw_fixes_path")
        ->RunSync('-k', '@'.$mw_fixes_change_level);
    print localtime(). " Sync -k returned ". Dumper(@sync_result);

    # 3. switch the client back to the stream it started with before
    #    post clone processing.

    print localtime()." Switching $p4ws back to $client_stream\n";
    $p4->fmsg("Unable to alter client $p4ws")
        ->RunClient('-s', '-S', $client_stream, $p4ws);

    return;
}

=item B<< $clonebuildarea->perfect_snapshot >>

Returns the perfect snapshot for cluster according to cluster, job and type.
You can call them without job and type too.
=cut

# TODO when $job is not passed, returns a JMD::Job
# when $job is passed as a number, returns a number
sub perfect_snapshot {
    my ($self, $cluster, $job, $type) = @_;

    if (!ref $cluster) {
        $cluster = $job
            ? $job->get_jmd_cluster
            : JMD::Cluster->new({name => $cluster});
    }
    $type ||= 'pass';

    if (!$job) {
        $job = $cluster->get_lkg_job
            or die "No LKG job id for $cluster, can't get snapshot\n";
        print "latest pass job for $cluster = $job\n";
    }

    my $anchor = $job->get_build_area;
    print "build area for latest_pass $job = $anchor\n";

    my $snapshot = $self->snapshot_for($cluster, $job, $type, $anchor)
        or die "No appropriate snapshot for $anchor exists\n";

    return wantarray ? ($snapshot, $job) : $snapshot;
}

=item B<< $clonebuildarea->snapshot_for >>

Returns snapshot according to the cluster, job, type and anchor.
This can be called without job, type and anchor.

=cut

sub snapshot_for {
    my ($self, $cluster, $job, $type, $anchor) = @_;

    my $aa = ArchiveArea->new({baseDir=>$anchor, owner=>$cluster});
    my ($ss) = $aa->list($job, $type, \undef)
        or return;

    my $snapshot = $ss->get_path;
    print "Found snapshot for $job: ".$ss->get_name." = $snapshot\n";

    return $snapshot;
}

=item B<< $clonebuildarea->get_branch_record >>

Returns the branch record object containing job, change number and 'branch file at change' information.

=cut

sub get_branch_record {
    my ($self, $args) = @_;
    my $classname = "MW::BranchHistory::" . ucfirst(lc($args->{action}));
    my $branch_history = $classname->new($args);
    return $branch_history->get_branch_record;
}

=item B<< $clonebuildarea->enable_sterile >>

This subroutine enables the sterile job workflow
for a cloning job.

=cut

sub enable_sterile {
    my ($self) = @_;
    return bless $self, 'BuildArea::PrepareBuildArea::Clone::SterileClone';
}

=item B<< $clonebuildarea->computeBranchDiff >>

This subroutine uses 'p4 diff2' to compute the difference between the
current branch (at the job change level) and the parent branch (at the
target change level).

target_stream is needed if the target change level is on a branch other
than the parent.

Please refer to the following wiki,

 http://inside.mathworks.com/wiki/Hybrid_Snap_logic_and_activities_in_cluster_bootstrap

=cut

sub computeBranchDiff {
    my ($self, $args, $left, $right) = @_;

    my @result = $self->get_p4->fmsg('Unable run diff2')
                    ->RunDiff2(@$args, '@'.$left, '@'.$right);
    return \@result;
}

sub processBranchDiff {
    my ($self, $diffResult, $mwfixes) = @_;

    # Compute the list of files which are identical and different.
    # An interesting Perforce issue we have here is that
    # a renamed file from parent which was renamed again in client of child
    # does not appear as a regular entry in the output of diff2,
    # but appears as a list with 2 undefined entries and one filename entry.
    # This map is to work around that issue.
    # (we have contacted Perforce about the issue)
    my @diffs = map {
                !ref $_->{depotFile}
                ? $_
                : $_->{status} eq 'right only'
                  ? {
                        status => $_->{status},
                        type => $_->{type}[2],
                        rev => $_->{rev}[2],
                        depotFile2 => $_->{depotFile}[2],
                    }
                  : ()
            } @$diffResult;

    my %unchanged;
    my @changed;
    # PLEASE NOTE: When status is 'right only', only depotFile2 is defined
    # *and* it is a path on the parent stream
    for (@diffs) {
        if ($_->{status} eq 'identical') {
            $unchanged{ $_->{depotFile} } = $_->{rev};
        } elsif ($mwfixes) {
            # Processing results for diff2 with mwfixes branch.

            # skip 'left only' records in diff2 as a lot of 'left only'
            # records are listed in output of diff from 'mwfixes' branch.
            # This means that file not present in the mwfixes. (Which is expected)
            if ($_->{status} ne 'left only') {
                my $depotFile = $self->get_rel_path($_->{depotFile} || $_->{depotFile2});
                push @changed, $depotFile
                    if $depotFile !~ m{^config/};
            }
        } else {
            # Processing results for diff2 with regular branch
            my $depotFile = $self->get_rel_path($_->{depotFile} || $_->{depotFile2});
            push @changed, $depotFile
                if $depotFile !~ m{^config/};
        }
    }

    return (\%unchanged, \@changed);
}

# Find the relative path of the file.
# This returns the filename as "matlab/toolbox/..." or "matlab/..."
# It gets rid of the stream names.
sub get_rel_path {
    my ($self, $file) = @_;
    my ($relPath) = ($file =~ m{ // [^/]* / [^/]* / (.*) }x);
    return $relPath;
}

sub get_clone_job_change_level {
    my ($self) = @_;
    my ($clonejob) = $self->get_source =~ m{snapshot/[^.]+\.(\d+)};
    $clonejob = JMD::Job->new({ job_id => $clonejob });
    return $clonejob->get_change_level;
}

1;
