=head1 NAME

BuildArea::PrepareBuildArea::Basic

=head1 SYNOPSIS

    use BuildArea::PrepareBuildArea::Basic;
    my $buildarea = BuildArea::PrepareBuildArea::Basic->new({
        job         => $job,
        p4ws        => $p4ws,
        p4port      => $p4port,
        p4user      => $p4user,
        lastjob     => $lastjob,
        bootstrap_args  => $args,
    });

    my $jobcl = $buildarea->get_jobcl;
    my $cluster = $buildarea->get_cluster;
    my $branch = $buildarea->depot_branch_of($path);
    my @depot_and_branch = $buildarea->depot_branch_of($path);

    $buildarea->prepare;
    $buildarea->set_source_area;
    $buildarea->create_area;
    $buildarea->update_area;
    $buildarea->get_config_changes;
    $buildarea->process_config_changes;
    $buildarea->sync_config;
    $buildarea->abort_job;
    $buildarea->crash_job;
    $buildarea->ensure_stream;


=head1 DESCRIPTION

Base Module for any build area.

=cut

package BuildArea::PrepareBuildArea::Basic;

use strict;
use warnings;

use Cwd            qw(getcwd);
use Class::Std;

use batmsg qw(BatMsg);
use BuildArea::SyncWorkspace;
use JMD::BootingMonitor;
use P4::Retry;
use PWS::ChangeProcessor;

=head1 CONSTRUCTOR

=over

=item
    BuildArea::PrepareBuildArea::Basic->new({
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

=item B<< $buildarea->get_job >>

Job number for which we are creating the build area.

=item B<< $buildarea->get_p4 >>

Perforce object to interact with perforce.
This is initialized while object invocation of Basic.

=item B<< $buildarea->get_p4ws >>

Name of the workspace/client.

=item B<< $buildarea->get_sbroot >>

The current root of the sandbox/client for which we are creating the build area.

=item B<< $buildarea->get_orig_sbroot >>

The original root of the sandbox/client when we created the client.

=item B<< $buildarea->clonefrom >>

Get the value from where we are cloning.
This could be an undef, cluster name, 'parent' for hybrid snap etc.

=item B<< $buildarea->get_cloneargs >>

Get the cloning arguments. This could help us decide to clone from last build or last pass.

=item B<< $buildarea->get_allow_below_lkg >>

Flag to see if this job is allowed to run below LKG.

=item B<< $buildarea->get_source >>

Path from where we are going to clone.

=item B<< $buildarea->get_bootstrap_args >>

Arguments passed into cluster_bootstrap.

=item B<< $buildarea->get_booting_monitor >>

Booting monitor to strobe JMD that we are still booting.

=item B<< $buildarea->get_is_clone_client >>

Flag to indicate if the client used is for cloning or not.

=item B<< $buildarea->get_expected_stream >>

Returns the expected stream set by reading the properties.

=item B<< DESCRIPTION >>

The constructor initializes the Perforce object and sets the orginal and sandbox root.

=cut

my %job_of                      : ATTR( :name<job> );
my %p4                          : ATTR( :name<p4> :default<> );
my %p4ws_of                     : ATTR( :name<p4ws> );
my %jobcl_of                    : ATTR( :name<jobcl> );
my %properties_of               : ATTR( :name<properties> :default<>);
my %sbroot_of                   : ATTR( :name<sbroot> :default<>);
my %orig_sbroot_of              : ATTR( :name<orig_sbroot> :default<> );
my %clonefrom_of                : ATTR( :name<clonefrom> :default<> );
my %cloneargs_of                : ATTR( :name<cloneargs> :default<> );
my %allow_below_lkg_of          : ATTR( :name<allow_below_lkg> :default<>);
my %source_of                   : ATTR( :name<source> :default<> );
my %use_sparse_of               : ATTR( :name<use_sparse> :default<> );
my %sparse_branch_of            : ATTR( :name<sparse_branch> :default<> );
my %bootstrap_args_of           : ATTR( :name<bootstrap_args> :default<> );
my %booting_monitor_of          : ATTR( :name<booting_monitor> :default<> );
my %is_clone_client_of          : ATTR( :name<is_clone_client> :default<>);

my %debug_of                    : ATTR( :name<debug> :default<>);
my %expected_stream_of          : ATTR( :name<expected_stream> :default<>);

sub BUILD {
    my ($self, $ident, $args_ref) = @_;
    # P4::Retry is printing the Warnings, which includes the 'up-to-date' messages.
    # Masking them by supplying a 'showwarn' hook.
    $args_ref->{p4} ||= P4::Retry->new({
                            showwarn => sub {
                                print STDERR map { / up-to-date.$/ ? () : "$_\n"} @_
                            },
                        });
    return;
}

sub START {
    my ($self, $ident, $args_ref) = @_;

    $self->set_use_sparse(1)
        if $self->get_job->is_using_fixes;

    my $p4 = $self->get_p4;

    $p4->SetPort($args_ref->{p4port});
    $p4->SetUser($args_ref->{p4user});
    $p4->SetClient($self->get_p4ws);
    $p4->SetProg($0); # name the program for the Perforce server-side logs
    $p4->Connect; # P4::Retry's connect retries until it succeeds
    my $client = eval { $p4->FetchClient };
    $self->crash_job("ERROR: Unable to access client ".$self->get_p4ws."\n", $p4->Errors)
        if !$client || !defined $client->_Update;

    my $sbroot = $client->_Root;
    $self->set_orig_sbroot($sbroot);
    $self->set_sbroot($sbroot);

    $self->set_p4($p4);

    $self->set_booting_monitor(JMD::BootingMonitor->new({
                                    job_id => $self->get_job,
                                    debug => $self->get_debug,
                                }))
        if !defined $self->get_booting_monitor;
}

=back

=head1 INSTANCE METHODS

=over 4

=item B<< $buildarea->prepare >>

This sets the source area. Later creates the clone if necessary and updates the build area.

=cut

sub prepare {
    my ($self) = @_;

    $self->get_booting_monitor->start;

    $self->set_source_area;
    print localtime()." source ".$self->get_source."\n";

    my $area = $self->create_area;
    $self->use_area($area);
    $self->update_area;

    $self->get_booting_monitor->stop;

    return;
}

=item B<< $buildarea->set_source_area >>

Relatively simple subroutine to set source to the client root.

=cut

sub set_source_area {
    my ($self) = @_;
    $self->set_source($self->get_sbroot);
    return;
}

=item B<< $buildarea->create_area >>

Abstract method for basic.

=cut

sub create_area {
    my ($self) = @_;
    return;
}

sub use_area {
    my ($self) = @_;
    return;
}

=item B<< $buildarea->update_area >>

Abstract method for basic.

=cut

sub update_area {
    my ($self) = @_;
    return;
}

=item B<< $buildarea->enable_sterile >>

Abstract method for basic.

=cut

sub enable_sterile {
    my ($self) = @_;
    return $self;
}

=item B<< $buildarea->get_config_p4ws_path >>

Return the path to the config directory as a client-relative path.

=cut

sub get_config_p4ws_path {
    my ($self) = @_;

    my $p4ws = $self->get_p4ws;
    my $config_path = "//$p4ws/config/...";
    return $config_path;
}

=item B<< $buildarea->get_config_changes >>

This subroutine Reverts opened file in the config path of Branch, syncs the config path
and then processes the qualification changes on the build area.

=cut

sub get_config_changes {
    my ($self) = @_;

    $self->get_booting_monitor->start;
    my $config_path = $self->get_config_p4ws_path;

    # first update cluster-volume build/config
    $self->revert_config_changes;

    $self->sync_config('-f', $config_path);
    $self->process_config_changes;

    if ($self->get_job->is_sterile) {
        $self->get_p4->fmsg("Unable to 'clean $config_path'")
            ->RunClean($config_path);
    }

    $self->get_booting_monitor->stop;
}

sub revert_config_changes {
    my ($self) = @_;
    my $config_path = $self->get_config_p4ws_path;

    # (NOTE: this revert does not guarantee that extraneous files do not exist
    #  in the config directory)

    print localtime()." Running: p4 revert $config_path\n";
    $self->get_p4->fmsg("Unable to 'revert -w $config_path'")
        ->RunRevert(-w => $config_path);
    return;
}

sub revert_k {
    my ($self) = @_;

    my $p4 = $self->get_p4;
    my $p4ws = $self->get_p4ws;
    my $client = $p4->FetchClient($p4ws);

    if ( ! defined $client->_Update ) {
        if ( $self->get_debug > 1) {
            print localtime()." Not running revert -k since client $p4ws does not exist\n";
        }
        return;
    };

    my $client_path = "//$p4ws/...";

    print localtime()." Running: p4 revert -k $client_path\n";

    # Clear the opened table (including the unshelved config, if any)
    # so that we can re-unshelve into the clone
    # RunFlush method seems to be not working here
    $p4->fmsg("Unable to run 'revert -k $client_path'")->RunRevert('-k', $client_path);

    return;
}

=item B<< $buildarea->process_config_changes >>

This method processes changes on the config area.
This could mean unshelving changes, merging the changes etc.

=cut

sub process_config_changes {
    my ($self) = @_;
    if (my @changes = $self->get_job->qualification_changes) {
        my $config_spec = "config/...";
        # You should unshelve the changes as a user if
        # Its a post commit job
        # and its not a qualification job
        # and the client used is for cloning (As all post-commit job do cloning).
        my $run_as_user = $self->get_job->is_post_commit
                            && !$self->get_job->is_qualification
                            && $self->get_is_clone_client
                                ? 1
                                : 0;
        my $change_processor = PWS::ChangeProcessor->new ({
            p4          => $self->get_p4,
            jobcl       => $self->get_jobcl,
            file_spec   => $config_spec,
            run_as_user => $run_as_user,
        });

        $change_processor->get_changes(\@changes);
    }
}

=item B<< $buildarea->sync_config >>

Syncs the config area using the flags passed to it.

=cut

sub sync_config {
    my ($self, $opts, $config_path) = @_;

    my @opts = ref $opts ? @$opts : defined $opts ? $opts : ();

    $config_path ||= $self->get_config_p4ws_path;
    $config_path .= '@' . $self->get_jobcl
        if $self->get_jobcl;

    # maybe this shouldn't be here, but it making debugging the bootstrap easier
    if ($self->get_debug > 1) {
        print "DEBUG: skipping p4 sync @opts $config_path\n";
        return;
    }
    return BuildArea::SyncWorkspace::run_sync($self->get_p4, \@opts, $config_path);;
}

=item B<< $buildarea->switch_perforce_client >>

Update new client to mimic old client

=cut

sub update_perforce_client {
    my ($self, $oldp4ws, $newp4ws) = @_;

    print localtime()." Updating Perforce client $newp4ws\n";

    my $p4 = $self->get_p4;
    my $client = $p4->FetchClient($oldp4ws);
    my $sbroot = $self->get_sbroot;

    # Workaround for g1109412: set AltRoot in main cluster perforce client
    # to avoid tripping up code that still uses it for the current job
    my $altroots = $client->_AltRoots || [];
    $client->_AltRoots([$altroots->[0] || (), $sbroot]);
    $p4->fmsg("Unable to update $oldp4ws")->SaveClient($client);

    my @view = $client->_View;
    for my $view (@view) {
        $view =~ s{\s+//$oldp4ws/}{ //$newp4ws/};
    }
    $client->_View(\@view);
    $client->_Client($newp4ws);
    $client->_Root($sbroot);
    $client->_AltRoots([]);
    my $options = $client->_Options;
    $options =~ s/\b noclobber \b/clobber/x; # This is for g1402856.
    $client->_Options($options);
    $p4->SaveClient($client);

    return;
}

=item B<< $buildarea->switch_perforce_client >>

Switches the perforce client in the build area

=cut
sub switch_perforce_client {
    my ($self, $newp4ws) = @_;

    print localtime()." Switching build area to Perforce client $newp4ws\n";

    my $p4 = $self->get_p4;
    my $sbroot = $self->get_sbroot;

    $p4->fmsg("Unable to update $newp4ws")->SetClient($newp4ws);
    $p4->SetCwd($sbroot);

    $self->set_p4ws($newp4ws);

    $self->update_dot_perforce;
    return;
}

=item B<< $buildarea->update_dot_perforce >>

Updates the .perforce file to represent the current client/port.

=cut

sub update_dot_perforce {
    my ($self, @lines) = @_;

    unshift @lines, 'P4PORT=' . $self->get_p4->GetPort;
    unshift @lines, 'P4CLIENT=' . $self->get_p4ws;
    print localtime()." Updating ".getcwd()."/.perforce to:\n\t@lines\n";
    $self->updateFile('.perforce', @lines);

    return;
}

=item B<< $buildarea->use_clone_client >>

Updates the perforce client to use "_clonebuild"

=cut

sub use_clone_client {
    my ($self) = @_;

    my $p4 = $self->get_p4;
    my $oldp4ws = $p4->GetClient;
    my $newp4ws = $self->get_job_client;

    return
        if $oldp4ws eq $newp4ws;

    # As it is a clone build we change it to a different client
    # so that we do not corrupt the build area.
    $self->switch_perforce_client($newp4ws);
    $self->revert_k;
    $self->update_perforce_client($oldp4ws, $newp4ws);
    $self->set_is_clone_client(1);
    return;
}

sub get_job_client {
    my ($self) = @_;
    my $p4user = $self->get_p4->GetUser;
    my $engine_id = $self->get_job->get_engine_id;
    return "$p4user.${engine_id}_build";
}

=item B<< $buildarea->create_sparse_branch >>

Create and use an //mwfixes branch for this job

=cut

sub create_sparse_branch {
    my ($self, $parent_stream) = @_;

    my $parent_change = $self->get_jobcl;
    my $mwfixes_stream = $self->get_job->get_fixes_branch_path;

    my $p4 = $self->get_p4;
    my $spec = $p4->FetchStream($mwfixes_stream);
    if (!defined $spec->_Update) {
        # return if job is LKG or job has qual changes
        return
            if ($self->get_job->is_lkg
                || $self->get_job->get_lkg_p4_change_level eq $self->get_jobcl
                || $self->get_job->qualification_changes);

        $p4->fmsg("Unable to create sparse stream $mwfixes_stream")
            ->RunStream(
                    -t => 'sparse_v1',
                    -P => $parent_stream.'@'.$parent_change,
                    $mwfixes_stream,
                );
    }
    $self->set_sparse_branch($mwfixes_stream);
    $self->set_expected_stream($mwfixes_stream);

    return $self->switch_to_sparse_branch;
}

=item B<< $buildarea->switch_to_sparse_branch >>

Use an //mwfixes branch for this job

=cut

sub switch_to_sparse_branch {
    my ($self) = @_;

    my $sparse_stream = $self->get_sparse_branch;
    my $p4 = $self->get_p4;

    $self->use_clone_client;
    my $p4ws = $self->get_p4ws;

    # switch the client to use the //mwfixes stream
    print localtime()." Switching $p4ws to $sparse_stream\n";

    $p4->fmsg("Unable to alter client $p4ws")
        ->RunClient('-s', '-S', $sparse_stream, '-f', $p4ws);
}

=item B<< $buildarea->abort_job >>

Puts the job in the completed state of ABORTED.

=cut

sub abort_job {
    my ($self, @msg) = @_;
    my $msg = join "\n", @msg;
    print localtime(). " ". $msg . "\n";
    $self->get_job->abort_job($msg);
    exit 1;
}

=item B<< $buildarea->crash_job >>

Crashes the job and DOES NOT remove it from queue.

=cut

sub crash_job {
    my ($self, @msg) = @_;
    my $msg = join "\n", @msg;
    print localtime(). " ". $msg;
    $self->get_job->crash_job($msg);
    exit 1;
}

=item B<< $buildarea->get_cluster >>

Returns cluster of this build area.

=cut

sub get_cluster {
    my ($self) = @_;
    return $self->get_job->get_jmd_cluster;
}

=item B<< $buildarea->depot_branch_of >>

Returns depot and branch information using the path.
Can return just branch too.

=cut

sub depot_branch_of {
    my ($self, $path) = @_;
    my ($depot, $branch) = $path =~ m{ ^ // ( [^/]+ ) / ( [^/]+ ) }x;
    return wantarray ? ($depot, $branch) : $branch;
}

=item B<< $buildarea->ensure_stream >>

Checks if the stream of current P4 client is
same as the expected stream.

=cut

sub ensure_stream {
    my ($self, $msg) = @_;

    my $expected_stream = $self->get_expected_stream
        or return;

    BatMsg("Ensuring $msg client's stream is correct...");

    my $client = $self->get_p4->FetchClient;
    my $current_stream = $client->_Stream;

    if ($expected_stream ne $current_stream) {
        die "Unexpected stream: $current_stream (Expected was $expected_stream)";
    }

    return;
}

# HELPER SUBROUTINES

sub updateFile {
    my ($self, $fileName, @lines) = @_;

    my $newContents = join "", map {($_, "\n")} @lines;
    my $oldContents = eval {slurp $fileName};

    return 0
        if defined $oldContents && $newContents eq $oldContents;

    open my $fh, '>', $fileName;
    print $fh $newContents;
    close $fh;
    return 1;
}

sub DEMOLISH {
    my ($self, $ident) = @_;
    $self->get_booting_monitor->stop;
}

1;
