=head1 NAME

BuildArea::PrepareBuildArea::Clone::SterileClone

=head1 SYNOPSIS

    use BuildArea::PrepareBuildArea::Clone::SterileClone;
    my $sterileclonebuildarea = BuildArea::PrepareBuildArea::Clone::SterileClone->new({
        job         => $job,
        p4ws        => $p4ws,
        p4port      => $p4port,
        p4user      => $p4user,
        lastjob     => $lastjob,
        bootstrap_args  => $args,
    });

    $sterileclonebuildarea->set_source_area;
    $sterileclonebuildarea->create_area;
    $sterileclonebuildarea->update_area;
    $sterileclonebuildarea->generate_build_area_files;

=head1 DESCRIPTION

Subclass Module to handle sterile jobs which want to clone.

=head1 SEE ALSO

BuildArea::PrepareBuildArea::Basic,
BuildArea::PrepareBuildArea::Clone,

http://inside.mathworks.com/wiki/Promote_clones_after_BaT_jobs#Updating_Sterile_job_workflow

=cut

package BuildArea::PrepareBuildArea::Clone::SterileClone;

use strict;
use warnings;

use Fatal qw( :void chdir mkdir );

use base qw( BuildArea::PrepareBuildArea::Clone );

use Class::Std;

use batfs::clone;

=head1 CONSTRUCTOR

=over

=item
    BuildArea::PrepareBuildArea::Clone::SterileClone->new({
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

=cut

# ******PLEASE NOTE******

# In a scenario where we do not have 'jobSterile' property enabled in the job directives,
# but it is enabled in the config XML files (batsettings or cluster XML) then this
# module will be enabled. However, enabling this module in such a scenario will not trigger
# BUILD and START subroutines as it is a blessed conversion.
#
# As of 7/20/2015, these subroutines have not been added.
# In the future if these are enabled then we need to figure out how to trigger the BUILD
# and START subroutines.

=back

=head1 INSTANCE METHODS

=over 4

=item B<< $sterileclonebuildarea->set_source_area >>

A no-op command.

=cut

sub set_source_area {
    my ($self) = @_;
    $self->set_source($self->get_sbroot);
    return;
}

=item B<< $sterileclonebuildarea->create_area >>

1. Create the empty volume.
2. Chdir to the empty directory.
3. Make the build directory.

=cut

sub create_area {
    my ($self) = @_;

    # Create empty volume.
    my $tag = $self->get_cluster.".".$self->get_job;
    print localtime()." Creating empty volume for cloning sterile job $tag\n";
    my $emptydir = eval {
                            batfs::clone::create_empty_volume(
                                            $self->get_sbroot,
                                            $tag
                                        );
                    };

    $self->crash_job("ERROR during making empty volume named $tag: $@")
        if $@;

    my $area = "$emptydir/build";

    # Create the 'build' directory.
    mkdir $area;
    print localtime()." Created empty directory $area\n";

    return $area;
}

=item B<< $sterileclonebuildarea->update_area >>

1. Generate the build area files (.perforce and mw_anchor)
2. Update perforce client by calling SUPER.
3. Update empty volume by unshelving
    config changes to the empty directory by calling SUPER.

=cut


sub update_area {
    my ($self) = @_;

    $self->generate_build_area_files;

    $self->SUPER::update_area;
}

=item B<< $sterileclonebuildarea->generate_build_area_files >>

An empty volume does not have the .perforce and mw_anchor file.
This subroutine creates them.

=cut

sub generate_build_area_files {
    my ($self) = @_;

    my $cluster = $self->get_cluster;

    # .perforce
    eval {

        $self->update_dot_perforce;

        # MW_ANCHOR
        $self->updateFile('mw_anchor', "MW_CLUSTER=$cluster\n");
    };

    $self->crash_job("ERROR while creating .perforce and mw_anchor files: $@")
        if $@;

    return 1;
}

=item B<< $sterileclonebuildarea->post_clone >>

No-Op subroutine just to override super class subroutine.
S
=cut
sub post_clone {
    my ($self) = @_;
    return;
}

1;
