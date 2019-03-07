=head1 NAME

BuildArea::JobInformation

=head1 SYNOPSIS

    use BuildArea::JobInformation;
    my $job = BuildArea::JobInformation->new({
        job_id       =>  $job_id,
    });

    my $value = $job->get_SET_dir_val($dir);
    my $mwtools_directive = $job->get_mwtools_directive;
    my $value = $job->is_lkg;
    my $clonefrom = $job->get_clone_directive;
    my $jobSterile = $job->get_jobSterile;


=head1 DESCRIPTION

Subclass Module to handle Directives and job information.

=head1 SEE ALSO

JMD::AcceptanceJob

=cut

package BuildArea::JobInformation;

use strict;
use warnings;

use base qw( JMD::AcceptanceJob );

use Class::Std;
use List::MoreUtils qw( uniq );

use batmsg qw(BatMsg);

=head1 CONSTRUCTOR

=over

=item
    my $job = BuildArea::JobInformation->new({
        job_id       =>  $job_id,
    });

Use $job_id as the job number.

=back

=head1 Constructor Arguments ACCESSOR METHODS

=over 4

=cut

=item B<< $job->get_cache_dirs >>

Cached directives from the job. These are set while object initialization.

=cut

my %cache_dirs_of   : ATTR( :name<cache_dirs> :default<> );
my %debug_of        : ATTR( :name<debug> :default<>);

sub START {
    my ($self, $ident, $args_ref) = @_;

    my @directives_list = $self->get_directives;
    my @dirs = uniq map {$_->get_directive} @directives_list;

    my %dir_bean = map { $_ => [$self->matching_directives($_,\@directives_list)]} @dirs;

    $self->set_cache_dirs(\%dir_bean);
}

=back

=head1 INSTANCE METHODS

=over 4

=item B<< $job->get_SET_dir_val >>

Returns the argument of the directive mentioned with macro SET.

=cut

sub get_SET_dir_val {
    my ($self, $dir) = @_;
    my @vals = map {/^$dir=(.*)/} @{$self->get_cache_dirs->{SET} || []};
    return $vals[-1];
}

=item B<< $job->get_mwtools_directive >>

Returns the argument of directive 'MW_TOOLS'.

=cut

sub get_mwtools_directive {
    my ($self) = @_;
    return $self->get_SET_dir_val('MW_TOOLS');
}

=item B<< $job->is_lkg >>

Returns true if job is configured to run at LKG.
Else returns false.

=cut

sub is_lkg {
    my ($self) = @_;
    return $self->is_p4_lkg;
}

=item B<< $job->is_sterile >>

Returns true if job directives have value of 'jobSterile' as 1 or true.
Else returns undef.

=cut

sub is_sterile {
    my ($self) = @_;
    my $val = $self->get_SET_dir_val('jobSterile')
        or return;

    return $val =~ /^[t1]/i;
}

=item B<< $job->get_clone_directive >>

Returns from where to create the clone from if necessary.
Checks the job directives for CLONE_BUILD.
Also, checks if its a qual or post-commit job and returns
self if it has an acceptance engine else returns the parent cluster.

=cut

sub get_clone_directive {
    my ($self) = @_;

    # We try to get the CLONE_BUILD directive from Job.
    # If if does not have it we check if the job is qualification
    # or Post-Commit and return the appropriate clonefrom value.

    # The CLONE_BUILD values from get_cache_dirs come as a list.
    # The correct value is from the last element in the list.
    # However it is highly unlikely that we will have 2 CLONE_BUILD entries.
    my $clonedest = $self->get_cache_dirs->{CLONE_BUILD} || [];
    my $clonefrom = $clonedest->[-1];
    if (defined $clonefrom) {
        return $clonefrom;
    }

    if ($self->is_qualification  || $self->is_post_commit) {
        # Check if cluster has an acceptance engine.
        # If yes then clone from self else clone from parent.
        $clonefrom = $self->get_jmd_cluster->has_acceptance_engine
                    ? ''
                    : $self->get_jmd_cluster->get_parent_cluster;
    }

    return $clonefrom;
}

# This is for debugging
sub boot_job {
    my ($self, @args) = @_;
    return $self->get_debug ? 1 : $self->SUPER::boot_job(@args);
}

sub find_cluster_from_path {
    my ($self, $path) = @_;

    # Get the cluster name from Properties
    BatMsg("Reading cluster name from properties of $path");
    my $props = MW::PropertiesFactory->create({ anchor => $path });
    my $clusterName = $props->value('MW_CLUSTER');
    BatMsg("Found cluster: $clusterName.");
    return $clusterName;
}

1;
