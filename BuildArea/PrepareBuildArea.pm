=head1 NAME

BuildArea::PrepareBuildArea

=head1 SYNOPSIS

    use BuildArea::PrepareBuildArea;
    my $buildarea = BuildArea::PrepareBuildArea->new({
        job         => $job,
        p4ws        => $p4ws,
        p4port      => $p4port,
        p4user      => $p4user,
        lastjob     => $lastjob,
        bootstrap_args  => \@args,
    });

=head1 DESCRIPTION

Factory module to get the appropriate build area type.
It returns either 'Basic', 'Clone' or 'HybridSnap'.

=cut

package BuildArea::PrepareBuildArea;

use strict;
use warnings;

use Data::Dumper;

use BuildArea::PrepareBuildArea::Basic;
use BuildArea::PrepareBuildArea::Clone;
use BuildArea::PrepareBuildArea::Clone::HybridSnap;
use BuildArea::PrepareBuildArea::Clone::SterileClone;
use BuildArea::PrepareBuildArea::Clone::Promote;
use BuildArea::PrepareBuildArea::Clone::Build;

=head1 CONSTRUCTOR

=over

=item
    my $buildarea = BuildArea::PrepareBuildArea->new({
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

=cut

sub new {
    my ($class, $args) = @_;

    # get the clonefrom value from argument or directives.
    my $clonefrom = $args->{job}->get_clone_directive;
    my $sterile = $args->{job}->is_sterile;

    my %cloneargs;

    if (!defined $clonefrom || $clonefrom eq 'none') {
        $class .= '::Basic';
    } else {
        $clonefrom ||= $args->{job}->get_jmd_cluster;
        # Split the clone_from arguments.
        ($clonefrom, my @cloneargs) = split /\s+/, $clonefrom;
        print localtime()."clonefrom $clonefrom, args = @cloneargs\n";
        %cloneargs = map {lc $_=>1} @cloneargs;

        if ($sterile) {
            $class .= '::Clone::SterileClone';
        } else {


            if ($clonefrom eq 'build') {
                # CLONE_BUILD build ...
                $class .= '::Clone::Build';
            } elsif ($clonefrom eq 'promote') {
                # CLONE_BUILD promote ...
                $class .= '::Clone::Promote';
            } elsif ($clonefrom eq 'parent') {
                # CLONE_BUILD parent ...
                $class .= '::Clone::HybridSnap';
            } else {
                # CLONE_BUILD Bcluster or CLONE_BUILD //some/path
                $class .= '::Clone';

            }
        }
    }

    $args->{clonefrom} = $clonefrom;
    $args->{cloneargs} = \%cloneargs;

    if (!$class->can('new')) {
        die "\n$class does not exist.\n\nThis is either a bug or this is a special build area. Check the directives.\n ";
    }

    return $class->new($args);
}

1;
