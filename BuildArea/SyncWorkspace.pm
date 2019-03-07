=head1 NAME

BuildArea::SyncWorkspace

=head1 SYNOPSIS

    use BuildArea::SyncWorkspace;
    my @result = BuildArea::SyncWorkspace::run_sync($p4, $args, @files);

=head1 DESCRIPTION

Module to handle sync in sandbox.
This does a part by part sync on the sandbox.

=cut

package BuildArea::SyncWorkspace;

use strict;
use warnings;

use Carp qw();
use Data::Dumper;
use List::MoreUtils qw( natatime );
use ResourceConfig::BatResourceConfig qw(getConfigurationValue);

=head1 INSTANCE METHODS

=over 4

=item B<< BuildArea::SyncWorkspace::run_sync >>

This subroutine runs 'p4 sync' with different arguments
on a list of files on an interval of 100000 files at a time.

=cut

sub run_sync {
    my ($p4, $args, @files) = @_;
    $args ||= [];

    my @result;
    my $file_chunk_size = getConfigurationValue('PERFORCE_SYNC_CHUNK_SIZE') || 100000;
    my $it = natatime $file_chunk_size, @files;
    while (my @vals = $it->()) {
        my $msg = @vals>1 ? "[".@vals." files]" : "@vals";
        print localtime()." Running: p4 sync @$args $msg\n";
        push @result, $p4->fmsg('Unable to sync')->RunSync(@$args, @vals);
    }

    # display all in-line sync warning messages
    print map {ref $_ ? () : "$_\n"} @result;
    print localtime()." Sync returned ", scalar (grep {ref $_} @result), " files\n";

    my %synced;
    for (@result) {
        $synced{$_->{action}}++
            if ref $_;
    }
    print "\t", join(" ", %synced), "\n";

    return @result;
}

1;