=head1 NAME

BuildArea::PrepareBuildArea::Clone::HybridSnap

=head1 SYNOPSIS

    use BuildArea::PrepareBuildArea::Clone::HybridSnap;
    my $hsbuildarea = BuildArea::PrepareBuildArea::Clone::HybridSnap->new({
        job         => $job,
        p4ws        => $p4ws,
        p4port      => $p4port,
        p4user      => $p4user,
        lastjob     => $lastjob,
        bootstrap_args  => $args,
    });

    my @results = $hsbuildarea->handle_deletes_and_renames($snapcl);

    $hsbuildarea->set_source_area;
    $hsbuildarea->find_last_promote;
    $hsbuildarea->post_clone;

=head1 DESCRIPTION

Subclass Module to handle hybrid snap activites after cloning of build area.

=head1 SEE ALSO

BuildArea::PrepareBuildArea::Basic,
BuildArea::PrepareBuildArea::Clone,
BuildArea::SyncWorkspace

http://inside.mathworks.com/wiki/Hybrid_Snap_logic_and_activities_in_cluster_bootstrap

=cut

package BuildArea::PrepareBuildArea::Clone::HybridSnap;

use strict;
use warnings;

use base qw( BuildArea::PrepareBuildArea::Clone );

use Class::Std;

use Fatal           qw( :void open );
use File::Basename  qw( dirname );
use List::MoreUtils qw( uniq );

use BuildArea::SyncWorkspace;
use JMD::Job;
use P4::SpecialChars qw();

use Data::Dumper;
=head1 CONSTRUCTOR

=over

=item
    BuildArea::PrepareBuildArea::Clone::HybridSnap->new({
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

=item B<< $hsbuildarea->get_parent_stream >>

Parent Stream of the cluster.

=item B<< $hsbuildarea->get_parentcl >>

Change Level that the parent is at.

=item B<< $hsbuildarea->get_branch_file_at_change >>

Change level at which the branch file for the current cluster is at.

=cut

my %parent_stream_of    : ATTR( :name<parent_stream> :default<> );
my %parentcl_of         : ATTR( :name<parentcl> :default<> );
my %branch_file_at_change_of : ATTR( :name<branch_file_at_change> :default<> );

=back

=head1 INSTANCE METHODS

=over 4

=item B<< $hsbuildarea->set_source_area >>

Calls proper subroutines depending on the clone arguments.
If the argument is 'noreset' then get the last build.
If the argument is 'incr' then get the latest pass.
If the source is still not known after the above then rebase from parent.

=cut

sub set_source_area {
    my ($self) = @_;

    # This is only allowed when doing hybrid snap.
    $self->set_allow_below_lkg(1);

    if ($self->get_cloneargs->{noreset}) {
        $self->find_last_build;
        if ($self->get_source) {
            return;
        }
    }

    # Abort job if this does not return correct values.
    my $branch_record;
    my $stream = $self->get_p4->FetchClient->_Stream;
    my $branch_name = $self->depot_branch_of($stream);
    eval {
        $branch_record = $self->get_branch_record({
                        action  => 'Snap',
                        branch  => $branch_name,
                        p4      => $self->get_p4,
                        path    => '.',
                        depot_path => $stream,
                        required_record => 'job',
                        identifier => '@'.$self->get_jobcl});
    };
    $self->crash_job("This branch does not have a proper SNAP job record ".$branch_name." $@")
        if $@;

    $self->set_snap_job_id($branch_record->{job});
    $self->set_snap_job_time($branch_record->{time});
    $self->set_branch_file_at_change($branch_record->{file_at_change});

    if ($self->get_cloneargs->{incr}) {
        eval { $self->find_latest_pass };
        if ($@) {
            print "Rebasing from parent: cannot incr: $@";
            $self->set_rebasing(1);
        }
    }

    if (!$self->get_source || $self->get_rebasing) {
        $self->find_last_promote;
    }

    return;
}

=item B<< $hsbuildarea->find_last_promote >>

This subroutine handles rebasing the build area from parent.

=cut

sub find_last_promote {
    my ($self) = @_;

    my $stream = $self->get_p4->FetchClient->_Stream;
    my $branch_name = $self->depot_branch_of($stream);

    my $stream_spec = eval { $self->get_p4->FetchStream($stream) }
        or $self->crash_job("Unable to fetch stream '$stream'\n", $self->get_p4->Errors);
    my $parent_stream = $stream_spec->{Parent};
    $self->set_parent_stream($parent_stream);

    my $snap_job_id = $self->get_snap_job_id;
    my $parentjob = JMD::Job->new({ job_id => $snap_job_id });

    my $parent = $parentjob->get_cluster;
    my $parentcl = $parentjob->get_p4_change_level;
    $self->set_parentcl($parentcl);

    # Make sure the clone will be backed by the same stream as the job and parent we're cloning from
    my ($described) = $self->get_p4->RunDescribe(-s => $parentcl);
    if (!$described || !$described->{path}) {
        $self->crash_job("Could not identify the path from change $parentcl");
    }
    if ($described->{path} !~ m/^$parent_stream\//) {
        $self->crash_job("Last SNAP job parent $parent does not match stream parent $parent_stream");
    }

    my $cluster_name = $self->get_cluster;
    print localtime()." Looking for last promotion from $cluster_name into $parent as of job $parentjob change $parentcl\n";

    my $branch_record = $self->get_branch_record({
                        action  => 'Promote',
                        branch  => $branch_name,
                        p4      => $self->get_p4,
                        path    => $parent_stream,
                        depot_path => $parent_stream,
                        required_record => 'change',
                        identifier => '@'.$parentcl});

    my $last_promote = eval { $branch_record->{change} };
    die "Parent branch $parent_stream does not have a proper promote record: $@"
        if $@;

    my $clonecl;
    # if no last promote found, then use our oldest change
    if ($last_promote) {
        $clonecl = $last_promote;
    } else {
        print localtime()." no last promoted change - will use first apparent change on $stream\n";
        # with current cluster creation cluster branch XML revision #2
        # is after branch is initially populated
        my @changes = $self->get_p4->RunChanges('-m1', "config/clusters/$cluster_name.xml#2");
        $clonecl = $changes[-1]{change};
    }
    print localtime()." last promoted change $clonecl\n";

    my $base = $parentjob->get_archive_area;
    print "Looking for $base\n";
    my $source = eval {batfs::clone::snap_path($base)};
    if (!$source) {
        $source = eval {$self->perfect_snapshot($parent, $parentjob)};
        $self->abort_job("\nUnable to determine source to clone: $@\n"
                        . "Check for these:\n"
                        . "1. Maybe you need to Snap.\n"
                        . "2. Maybe your cluster no longer has the corresponding build area.\n"
                        . "3. If above does not work, contact Bat-Help.\n")
            if !$source;
    }

    $self->set_rebasing(1);
    $self->set_source($source);
    $self->set_clonecl($clonecl);
    $self->set_clone_cluster($parent);

    return;
}

sub rebase_token_file {
    my ($self) = @_;
    return '.rebase-snap';
}

=item B<< $hsbuildarea->post_clone >>

This subroutine handles all the activites to be performed after cloning in a hybrid snap cluster.
These set of activites prevent unnecessary build churn.
Please refer to this wiki,

http://inside.mathworks.com/wiki/Hybrid_Snap_logic_and_activities_in_cluster_bootstrap

=cut

sub post_clone {
    # move forward any files that are unchanged from our parent
    my ($self) = @_;

    if (!$self->get_rebasing) {
        return $self->SUPER::post_clone;
    }

    my $stream = $self->get_p4->FetchClient->_Stream;
    my $jobcl = $self->get_jobcl;
    my $parent_stream = $self->get_parent_stream;
    my $parentcl = $self->get_parentcl;
    my $clonecl = $self->get_clonecl;

    open my $fh, '>', $self->rebase_token_file;

    # Find all files (outside of config) that PWS will sync.
    # Note: The clone was initially sync'd to $clonecl,
    # and the config was further sync'd to the $jobcl.
    print localtime()." Finding all files to sync between $clonecl and $jobcl\n";
    my @will_sync = map {
                    ref $_ && $_->{depotFile} !~ m{$stream/config/}
                    ? $_->{depotFile}
                    : ()
                } BuildArea::SyncWorkspace::run_sync($self->get_p4, ['-n'], '@'.$jobcl);

    print localtime()." Found ".@will_sync." files\n";
    return
        unless @will_sync;

    # Computing diff between parent and child.
    # We will sync ahead the identical files.
    # We will sync the different files to #0 and later manually unlink them.

    # Find branch diff between parent mw branch and cluster mw branch.
    print localtime()." Computing diff between $parent_stream\@$parentcl and $stream\@$jobcl\n";
    my $diffResult_mw = $self->computeBranchDiff([-S => $stream], $jobcl, $parentcl);
    my ($unchanged, $changed_files) = $self->processBranchDiff($diffResult_mw);

    # For more information on the logic for mwfixes jobs, please check the following wiki,
    # http://inside.mathworks.com/wiki/Chaser_Workflow_changes_for_Bootstrap_and_PWS

    # Check if the rebase job is an mwfixes.
    my $clone_change_level = $self->get_clone_job_change_level;
    my $mw_fixes_cl = $clone_change_level->get_fixes_changelevel;

    if ($mw_fixes_cl) {
        my $diff_with_mwfixes = 1; # Flag to indicate if 'p4 diff2' is with mwfixes branch
        my $mw_fixes_path = $clone_change_level->get_fixes_path;

        # Find branch diff between parent mwfixes branch and cluster mw branch.
        print localtime()." Computing diff between $mw_fixes_path/...\@$mw_fixes_cl and $stream/...\@$jobcl\n";
        my @diffResult_mwfixes = $self->get_p4->fmsg('Unable run diff2')
                                    ->RunDiff2($stream."/...@".$jobcl, $mw_fixes_path."/...@".$mw_fixes_cl);
        my ($unchanged_mwfixes, $changed_files_mwfixes) = $self->processBranchDiff(\@diffResult_mwfixes, $diff_with_mwfixes);

        # Merge changed files of diff results.
        $changed_files = [uniq @$changed_files, @$changed_files_mwfixes];

        # Merge the unchanged results
        # Also, remove the unchanged_mwfixes from the union of the changed files (changed_files+changed_files_mwfixes).
        # This is because as part of the first diff, files edited on the parent mwfixes
        # come in changed. However for the second diff between child and mwfixes,
        # files edited on the parent mwfixes come as unchanged.
        for my $file (keys %$unchanged_mwfixes) {
            if (!$unchanged->{$file}) {
                $unchanged->{$file} = $unchanged_mwfixes->{$file};
            }
            @$changed_files = grep { $_ ne $self->get_rel_path($file)} @$changed_files;
        }

        # Remove the changed mwfixes files from unchanged list too.
        my %unchanged_rel_paths = map { $self->get_rel_path($_) => 1 } keys %$unchanged;
        my @changed_overlap_in_unchanged = grep { $unchanged_rel_paths{$_}}  @$changed_files_mwfixes;
        for (@changed_overlap_in_unchanged) {
            # Adding stream to the file as it is a relative path.
            delete $unchanged->{$stream."/".$_};
        }
    } else {
        print localtime(). " Clone job was not an mwfixes job.\n";
    }

    print localtime()." Found ".(keys %$unchanged)." unchanged files on wide branches\n";
    print localtime()." Found ". @$changed_files ." changed files on wide branches\n";

    # Sync changed file to #0 to sync correct revision later. (g1122228)
    print localtime()." Syncing the changed files to Rev #0\n";
    my @syncRes = BuildArea::SyncWorkspace::run_sync($self->get_p4, [], map {"$stream/$_#0"} @$changed_files);

    # Decode Special characters in the file paths
    $changed_files = $self->decode_file_paths($changed_files);

    # XXX remaining?  it's the same list
    print localtime(). " Unlinking remaining ".@$changed_files." changed files:\n";
    my @changed_files_directories;
    for my $file (@$changed_files) {
        if (unlink $file) {
            print "\t$file\n";
            # Add the directory names to a list.
            push @changed_files_directories, dirname $file;
        } elsif (-e $file || -l $file){ # Print err only if file exists and cant be synced.
             print "\tFailed to unlink $file:  $!\n";
        }
    }

    # Delete the empty directories after unlinking files.
    # This is for g1413468.
    rmdir uniq @changed_files_directories;

    # Update the unchanged files with correct Revs.
    my @sync_ahead_unchanged = map {
                        exists $unchanged->{$_}
                        ? "$_#".$unchanged->{$_}
                        : ()
                    } @will_sync;
    print localtime()." Found ".@sync_ahead_unchanged." unchanged files to sync ahead\n";

    BuildArea::SyncWorkspace::run_sync($self->get_p4, [qw( -k -L )],  @sync_ahead_unchanged)
        if @sync_ahead_unchanged;

    # Update Have table with deletes and move/deletes (renames)
    $self->handle_deletes_and_renames($self->get_branch_file_at_change);

    return;
}

=item B<< $hsbuildarea->handle_deletes_and_renames >>

This subroutine handles deletes and renames that come while snapping in a hybrid snap cluster.

Please refer to the following wiki,

http://inside.mathworks.com/wiki/Hybrid_Snap_logic_and_activities_in_cluster_bootstrap

=cut

# Update Have table of client with deletes and move/deletes.
# As these do not come up while doing diff2 (g1124465)
sub handle_deletes_and_renames {
    my ($self, $snapcl) = @_;

    my $stream = $self->get_p4->FetchClient->_Stream;
    my $parent_stream = $self->get_parent_stream;
    my $parentcl = $self->get_parentcl;

    # 1. Use Fstat to calculate the deleted entries on parent stream at parentcl
    #   (from where snap occurs)
    # 2. Use Fstat to calculate the deleted entries on child stream at snapcl
    #   (Changelist submitted on child after snap)
    # 3. Find all the files which were deletes or move/deletes at parentcl and snapcl.
    # 4. Sync ahead all those files

    my @deletes_parent = $self->get_p4->RunFstat("-F", "headAction~=.*delete",
                                             "$parent_stream/...\@$parentcl");
    my @deletes_child = $self->get_p4->RunFstat("-F", "headAction~=.*delete",
                                             "$stream/...\@$snapcl");

    my %deletes_parent = map {
                        $self->get_rel_path($_->{depotFile}) => $_->{headAction}
                    } @deletes_parent;

    my %deletes_child = map {
                        $self->get_rel_path($_->{depotFile}) => $_->{headAction}
                    } @deletes_child;

    my @deletes = map {
                        $deletes_child{$_} eq  ($deletes_parent{$_} || '')
                        ? "$stream/$_\@$snapcl"
                        : ()
                    } keys %deletes_child;

    print localtime()." Found ".@deletes." deleted or move/deleted files\n";

    my @result = BuildArea::SyncWorkspace::run_sync($self->get_p4, ['-k'], @deletes);
    return @result;
}

# Helper Function to decode the % encoded file depot paths
sub decode_file_paths {
    my ($self, $files) = @_;

    for (@$files) {
        $_ = P4::SpecialChars->decode_special_chars($_);
    }

    return $files;
}

1;
