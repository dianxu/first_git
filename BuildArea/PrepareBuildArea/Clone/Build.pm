=head1 NAME

BuildArea::PrepareBuildArea::Clone::Build

=head1 SYNOPSIS

    use BuildArea::PrepareBuildArea::Clone::Build;
    my $buildarea = BuildArea::PrepareBuildArea::Clone::Build->new({
        job         => $job,
        p4ws        => $p4ws,
        p4port      => $p4port,
        p4user      => $p4user,
        lastjob     => $lastjob,
        bootstrap_args  => $args,
    });

    $buildarea->set_source_area;
    $buildarea->post_clone;
    $buildarea->find_latest_pass;
    $buildarea->find_latest_build_job;

=head1 DESCRIPTION

Subclass Module to handle jobs cloning from Build
clusters using sparse branches.

=head1 SEE ALSO

BuildArea::PrepareBuildArea::Promote

=cut

package BuildArea::PrepareBuildArea::Clone::Build;

use strict;
use warnings;

use base qw( BuildArea::PrepareBuildArea::Clone );

use Class::Std;
use File::Basename;
use Fatal qw( :void open );

use JMD::Cluster;
use JMD::Job;
use BuildArea::SyncWorkspace;
use batfs::clone;

=head1 CONSTRUCTOR

=over

=item

    BuildArea::PrepareBuildArea::Clone::Build->new({
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

=item B<< $buildarea->get_build_cluster >>

Name of the build cluster to clone from.
Defaults to "_build" for each "_integ"

=item B<< $buildarea->get_sparse_branch >>

Sparse fixes branch for the build job.
Defaults to C<//mwfixes/>I<branch.change>

=item B<< $buildarea->get_build_job >>

Job number of build job to clone.

=back

=cut

my %build_cluster_of            : ATTR( :name<build_cluster> :default<> );
my %build_job_of                : ATTR( :name<build_job> :default<> );


sub START {
    my ($self, $ident, $args_ref) = @_;

    if (!defined $self->get_build_cluster) {
        # XXX needs to be fixed to not embed this
        my $build_cluster = $self->get_cluster;
        $build_cluster .= '_build';
        $self->set_build_cluster($build_cluster);
    }
    if (!defined $self->get_sparse_branch) {
        my $mwfixes_stream = $self->get_job->get_fixes_branch_path;
        $self->set_sparse_branch($mwfixes_stream);
    }
}


=head1 INSTANCE METHODS

=over 4

=item B<< $buildarea->set_source_area >>

Calls proper subroutines depending on the clone arguments.
If the argument is 'noreset' then get the last build.
If the argument is 'incr' then get the latest pass based on 'promote' records.
If the source is still not known after the above then rebase from last promote.

=cut

sub set_source_area {
    my ($self) = @_;

    if ($self->get_cloneargs->{noreset} || $self->get_cloneargs->{incr}) {
        # incr wants to restrict this to the last passed job
        $self->find_last_build;
        if (my $source = $self->get_source) {
            print "Noreset: using source $source\n";
            return;
        }
    }

    $self->find_latest_build_job;

    if (!$self->get_source) {
        my $clonejob = $self->get_build_job;
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
    }

    return;
}

=item B<< $buildarea->post_clone >>

Updates the post clone activities for build area using sparse branches.

1. Switch to the sparse branch
2. Sync -k all of the sparse branch (including files we might not yet have)
3. Use reconcile -w to force our sparse branch to match Perforce

=cut

sub post_clone {
    my ($self) = @_;

    if (!$self->get_rebasing) {
        return $self->SUPER::post_clone;
    }

    open my $fh, '>', $self->rebase_token_file;

    $self->switch_to_sparse_branch;
    $self->set_use_sparse(0);

    my $sparse = $self->get_sparse_branch;
    $self->set_expected_stream($sparse);

    my @sunk = BuildArea::SyncWorkspace::run_sync($self->get_p4, ['-k'], $sparse.'/...');
    print localtime()." Found ".@sunk." files on $sparse\n";

    $self->get_p4->fmsg("Unable to switch to $sparse~CTB stream")
        ->RunClient('-s', '-S', $sparse.'~CTB');

    my @reconciled = $self->get_p4->fmsg("Unable to reconcile")
        ->RunReconcile('-w', $sparse.'/...');

    print localtime()." Updated ".@reconciled." files from $sparse\n";
    print map {$_->{depotFile}.'#'.$_->{rev}.' '.$_->{action}."\n"} @reconciled;

    $self->get_p4->fmsg("Unable to switch back to $sparse stream")
        ->RunClient('-s', '-S', $sparse);

    return;
}

=item B<< $buildarea->find_latest_pass >>

Sets the source and clone change level using the last pass of the cluster.

=cut

sub find_latest_pass {
    my ($self, $latest_promote_info) = @_;

    die 'XXX unimplemented';
}

=item B<< $buildarea->find_latest_build_job >>

This returns the latest build job for the change level of this job.

=cut

sub find_latest_build_job {
    my ($self) = @_;

    my $build_cluster = $self->get_build_cluster;
    # reverse the list from the JMD in order to get the latest job
    # at any particular change level
    my %latest_jobs = map {($_->get_p4_change_level => $_)}
                        reverse
                        JMD::Cluster->get_jobs(
                            10,
                            $build_cluster,
                            undef,undef,undef,undef,['ACCEPTED']
                        );

    my $change_level = $self->get_job->get_p4_change_level;
    my $build_job = $latest_jobs{$change_level}
        or $self->abort_job("Unable to determine job to clone in $build_cluster for change $change_level");

    $self->set_build_job($build_job);
    return;
}

1;
