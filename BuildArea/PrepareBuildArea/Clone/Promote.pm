=head1 NAME

BuildArea::PrepareBuildArea::Clone::Promote

=head1 SYNOPSIS

    use BuildArea::PrepareBuildArea::Clone::Promote;
    my $promotebuildarea = BuildArea::PrepareBuildArea::Clone::Promote->new({
        job         => $job,
        p4ws        => $p4ws,
        p4port      => $p4port,
        p4user      => $p4user,
        lastjob     => $lastjob,
        bootstrap_args  => $args,
    });

    $promotebuildarea->set_source_area;
    $promotebuildarea->post_clone;
    $promotebuildarea->find_latest_pass;
    $promotebuildarea->find_latest_promote_info;

=head1 DESCRIPTION

Subclass Module to handle jobs cloning from Build clusters.
At the moment it is only used for Bmain cluster.

=head1 SEE ALSO

BuildArea::PrepareBuildArea::Basic,
BuildArea::PrepareBuildArea::Clone,
BuildArea::PrepareBuildArea::Clone::HybridSnap,

=cut

package BuildArea::PrepareBuildArea::Clone::Promote;

use strict;
use warnings;

use base qw( BuildArea::PrepareBuildArea::Clone );

use Class::Std;
use Perl6::Slurp   qw(slurp);
use Data::Dumper;

use File::Basename;

use Fatal qw( :void open );

use JMD::Job;
use BuildArea::SyncWorkspace;
use MW::BranchHistory::Record;
use batfs::clone;

=head1 CONSTRUCTOR

=over

=item
    BuildArea::PrepareBuildArea::Clone::Promote->new({
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

=item B<< $promotebuildarea->get_promote_source_stream >>

Stream of the promote branch from where we are cloning.

=item B<< $promotebuildarea->get_promote_source_cl >>

Change level that the promote branch is at.

=item B<< $promotebuildarea->get_branch_file_at_change >>

Change level at which the branch file for the current cluster is at.

=cut

my %promote_source_stream_of    : ATTR( :name<promote_source_stream> :default<> );
my %promote_source_cl_of        : ATTR( :name<promote_source_cl> :default<> );
my %branch_file_at_change_of    : ATTR( :name<branch_file_at_change> :default<> );
my %latest_promote_info_of      : ATTR( :name<latest_promote_info> :default<> );

=back

=head1 INSTANCE METHODS

=over 4

=item B<< $promotebuildarea->set_source_area >>

Calls proper subroutines depending on the clone arguments.
If the argument is 'noreset' then get the last build.
If the argument is 'incr' then get the latest pass based on 'promote' records.
If the source is still not known after the above then rebase from last promote.

=cut

sub set_source_area {
    my ($self) = @_;

    if ($self->get_cloneargs->{noreset}) {
        $self->find_last_build;
        if (my $source = $self->get_source) {
            print "Noreset: using source $source\n";
            return;
        }
    }

    my $latest_promote_info = $self->find_latest_promote_info;

    $self->crash_job("This branch does not have any promote records ".$self->get_cluster)
        if !$latest_promote_info;

    if ($self->get_cloneargs->{incr}) {
        eval { $self->find_latest_pass };
        if ($@) {
            print "Rebasing from last promote: cannot incr: $@";
        } elsif (my $source = $self->get_source) {
            print "Incr: using source $source\n";
            return;
        }
    }

    if (!$self->get_source) {
        my $clonejob = $latest_promote_info->{job};
        $clonejob = JMD::Job->new({ job_id => $clonejob });
        my $clonecluster = $clonejob->get_jmd_cluster;
        my $clonecl = $clonejob->get_p4_change_level;

        # Set all the clone job and cl values here.
        my $base = $clonejob->get_archive_area;
        print "Looking for $base\n";
        my $source = eval {batfs::clone::snap_path($base)};
        if (!$source) {
            $source = eval {$self->perfect_snapshot($clonecluster, $clonejob)};
            $self->abort_job("Unable to determine source to clone: $@")
                if !$source;
        }

        print "Rebase: using source $source\n";
        $self->set_source($source);
        $self->set_clonecl($clonecl);
        $self->set_clone_cluster($clonecluster);
        $self->set_rebasing(1);
        $self->set_promote_source_stream("//mw/".$clonecluster);
        #XXX: Promote and clone change level are the same. Change this later.
        $self->set_promote_source_cl($clonecl);
    }

    return;
}

# When rebasing, force the have-table for the clone to initially be empty.
# For incr or noreset, don't change the have-table at all.
sub get_clone_base_change {
    my ($self) = @_;

    return $self->get_rebasing ? 0 : undef;
}

=item B<< $promotebuildarea->post_clone >>

Updates the clone for clusters rebasing from promotes. This is similar to hybrid
snap activities.

1. Finds all the changes to sync.
2. Compute difference in current branch and the promote source branch.
3. Find the changed and unchanged files.
4. Sync forward all the unchanged files.

=cut

sub post_clone {
    my ($self) = @_;

    if (!$self->get_rebasing) {
        return $self->SUPER::post_clone;
    }

    my $stream = $self->get_p4->FetchClient->_Stream;
    my $jobcl = $self->get_jobcl;
    my $promote_stream = $self->get_promote_source_stream;
    my $promotecl = $self->get_promote_source_cl;
    my $clonecl = $self->get_clonecl;

    open my $fh, '>', $self->rebase_token_file;

    # Find all files (outside of config) that PWS will sync.
    # Note: The clone was initially sync'd to @0
    # and the config was further sync'd to the $jobcl.
    print localtime()." Finding all files to sync to $jobcl\n";
    my @will_sync = map {
                    ref $_ && $_->{depotFile} !~ m{$stream/config/}
                    ? $_->{depotFile}
                    : ()
                } BuildArea::SyncWorkspace::run_sync($self->get_p4, ['-n'], '@'.$jobcl);

    print localtime()." Found ".@will_sync." files\n";
    return
        unless @will_sync;
    # Computing diff between promoted PP branch change level
    # and the promote as it exists on our branch
    print localtime()." Computing diff between $promote_stream\@$promotecl and $stream\@$jobcl\n";
    my $diffResult = $self->computeBranchDiff([-S => $stream, -P => $promote_stream], $jobcl, $promotecl);
    my ($unchanged, $changed_files) = $self->processBranchDiff($diffResult);
    print localtime()." Found ".(keys %$unchanged)." unchanged files on wide branches\n";
    print localtime()." Found ". @$changed_files ." changed files on wide branches\n";
    print Dumper($changed_files);

    my $latest_promote_info = $self->get_latest_promote_info;
    my $mwfixes = $latest_promote_info->{mwfixes};
    # until PBSP removes the mwfixes section when doing a new promote,
    # only use the mwfixes data if it is newer than the latest promote.
    if ($mwfixes && $mwfixes->{change} > $latest_promote_info->{change}) {
        my ($desc) = $self->get_p4->fmsg("Unable to run 'p4 describe' on change $mwfixes->{change}")
                                ->RunDescribe( $mwfixes->{change} );
        my ($fixes_branch) = $desc->{depotFile}[0] =~ m{^(//[^/]+/[^/]+)};
        my $branch_spec = 'tmp::'.$stream.'-to-'.$fixes_branch;
        print localtime()." Computing diff between $fixes_branch\@$mwfixes->{change} and $stream\@$jobcl\n";
        my $diffResult2 = $self->computeBranchDiff([-b => $branch_spec], $jobcl, $mwfixes->{change});
        my ($unchanged2, $changed_files2) = $self->processBranchDiff($diffResult2);
        print localtime()." Found ".(keys %$unchanged2)." unchanged files on wide branches\n";
        print Dumper($unchanged2);
        print localtime()." Found ". @$changed_files2 ." changed files on wide branches\n";

        my %changed_files = map {$_=>1} @$changed_files;
        for my $file (keys %$unchanged2) {
            my $rel = $self->get_rel_path($file);
            delete $changed_files{$rel};
            $unchanged->{"$stream/$rel"} = $unchanged2->{$file};
        }
        $changed_files = [keys %changed_files];
        print localtime()." Reconciled to ".(keys %$unchanged)." unchanged files on wide branches\n";
        print localtime()." Reconciled to ". @$changed_files ." changed files on wide branches\n";
    }

    print localtime(). " Unlinking ".@$changed_files." changed files:\n";
    print Dumper($changed_files);
    for my $file (@$changed_files) {
        if (unlink $file) {
            print "\t$file\n";
        } elsif (-e $file || -l $file){ # Print err only if file exists and cant be synced.
             print "\tFailed to unlink $file:  $!\n";
        }
    }

    # Update the unchanged files with correct Revs.
    my @sync_ahead_unchanged = map {
                        exists $unchanged->{$_}
                        ? "$_#".$unchanged->{$_}
                        : ()
                    } @will_sync;
    print localtime()." Found ".@sync_ahead_unchanged." unchanged files to sync ahead\n";
    print Dumper(\@sync_ahead_unchanged);

    BuildArea::SyncWorkspace::run_sync($self->get_p4, [qw( -k -L )],  @sync_ahead_unchanged)
        if @sync_ahead_unchanged;

    return;
}

=item B<< $promotebuildarea->find_latest_pass >>

Sets the source and clone change level using the last pass of the cluster.
It also checks if there is a new promote and do we have to rebase from the latest promote?

=cut

sub find_latest_pass {
    my ($self) = @_;

    my $latest_promote_info = $self->get_latest_promote_info;
    my $latest_promote_change = $latest_promote_info->{change};

    # Get the latest pass job info
    my ($pass_snapshot, $latest_pass_job) = $self->perfect_snapshot($self->get_cluster);

    my $latest_pass_cl = $latest_pass_job->get_p4_change_level;

    my $stream = $self->get_p4->FetchClient->_Stream;

    # use the same branch history file we found the promote in
    my $promoted_from = basename($latest_promote_info->{branch_file});

    my $branch_record = $self->get_branch_record({
                            action  => 'Promote',
                            branch  => $promoted_from,
                            p4      => $self->get_p4,
                            path    => $pass_snapshot,
                            depot_path => $stream,
                            required_record => 'change',
                            identifier => '@'.$latest_pass_cl,
                        });

    # promote change level in last passed job
    my $pass_promote_change = $branch_record->{change};

    if ($pass_promote_change eq $latest_promote_change) {
        # Last Promote job has not changed; reclone the old build area
        print "Last Promote job has not changed - cloning $pass_snapshot\n";
        my $source = $pass_snapshot;
        my $clonecl = $self->get_cluster->get_lkg_p4_change_level;
        print "cloning own job $latest_pass_job with have table at change level $clonecl\n";
        $self->set_source($source);
        $self->set_clonecl($clonecl);
        $self->set_clone_cluster($self->get_cluster);
        # Mark clone as promotable for incremental Job.
        $self->set_clone_promotable(1);
    } else {
        print "Last promote has changed. Rebasing from latest promote.\n";
    }

    return;
}

=item B<< $promotebuildarea->find_latest_promote_info >>

This returns the latest promote info for the branch.

=cut

sub find_latest_promote_info {
    my ($self) = @_;

    # Find the build area and cluster name to clone from.
    my ($change) = $self->get_p4->fmsg("Unable to run p4 changes for ".$self->get_cluster)
                                ->RunChanges('-m1', 'config/branch/promote/*@'.$self->get_jobcl);

    # This change should be the last promote on this branch
    # For Bmain it should be promote from Bmain_PP.
    my ($desc) = $self->get_p4->fmsg("Unable to run 'p4 describe' on change $self")
                                ->RunDescribe( $change->{change} );

    my @depotFiles = @{$desc->{depotFile}};
    my @actions = @{$desc->{action}};

    my $promoteFile;
    my $promotePattern = qr{^//[^/]+/[^/]+/config/branch/promote/(.*)};
    my @wanted = qw( add edit );
    my %wanted = map {$_=>1} @wanted;

    for (my $i = 0; $i < @depotFiles; $i++) {
        # If file matches config/branch/promote and is an add or edit
        if ($depotFiles[$i] =~ qr{$promotePattern} && $wanted{$actions[$i]}) {
            $promoteFile = $depotFiles[$i];
            last;
        }
    }

    return
        if !$promoteFile;

    my ($where) = $self->get_p4->RunWhere($promoteFile);

     my $latest = MW::BranchHistory::Record->read_branch_file_from_local_sandbox($where->{path});
     print "Latest promote data:\n", Dumper($latest);

     $self->set_latest_promote_info($latest);
     return $latest;
}

1;
