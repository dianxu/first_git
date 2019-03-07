=head1 NAME

BuildArea::ClusterXMLCreator - Merge 2 cluster XMLs

=head1 SYNOPSIS

    use BuildArea::ClusterXMLCreator;
    my $clusterXMLCreator = BuildArea::ClusterXMLCreator->new({
        job         => $job,
        src_file    => $src_file,
        tgt_file    => $tgt_file,
        batBranch   => $batBranch,
    });

    $clusterXMLCreator->create;
    $clusterXMLCreator->write_cluster_xml($fileName);

=head1 DESCRIPTION

Module to create XML files for analysis and hybrid snap clusters.
It uses a source XML of the cluster we clone from and another
source XML of the current cluster.

This logic is based on the schema decsribed in
the following wiki,
http://batdoc/mwe/manual.html

=head1 SEE ALSO

BuildArea::ClusterXMLCreator::Platform;
BuildArea::ClusterXMLCreator::Properties;
BuildArea::ClusterXMLCreator::XMLSchema;

=cut

package BuildArea::ClusterXMLCreator;

use strict;
use warnings;

use Class::Std;

use Cwd qw( getcwd );
use XML::LibXML;

use BuildArea::ClusterXMLCreator::Platform;
use BuildArea::ClusterXMLCreator::Properties;
use BuildArea::ClusterXMLCreator::XMLSchema;

=head1 CONSTRUCTOR

=over

=item

Use $job as the BuildArea::JobInformation object. This cannot be undef.

Use $src_file as the path of the cluster XML we are cloning from. This cannot be undef.

Use $tgt_file as the path of the current cluster XML. This cannot be undef.

Use $tgt_file as the name of the source cluster. This cannot be undef.

=back

=head1 INSTANCE ACCESSOR METHODS

=over 4

=item B<< $clusterXMLCreator->get_job >>

Job object for the current job.

=item B<< $clusterXMLCreator->get_src_file >>

Path of clone cluster XML.

=item B<< $clusterXMLCreator->get_tgt_file >>

Path of the current cluster XML.

=item B<< $clusterXMLCreator->get_doc >>

Document Root of the XML we will end up using.
Here it will be of clone cluster.

=item B<< $clusterXMLCreator->get_src_dom >>

DOM root of clone cluster XML.

=item B<< $clusterXMLCreator->get_tgt_dom >>

DOM root of current cluster XML.

=item B<< $clusterXMLCreator->get_xml_schema >>

XMLSchema object to obtain the location of various
elements in XML.

=back

=cut

my %job_of         : ATTR( :name<job> );
my %src_file_of    : ATTR( :name<src_file> );
my %tgt_file_of    : ATTR( :name<tgt_file> );
my %doc_of                  : ATTR( :get<doc>  :set<doc> :default<> );
my %src_dom_of     : ATTR( :get<src_dom>  :set<src_dom> :default<> );
my %tgt_dom_of     : ATTR( :get<tgt_dom>  :set<tgt_dom> :default<> );
my %xml_schema_of  : ATTR( :get<xml_schema>  :set<xml_schema> :default<> );
my %batBranch_of   : ATTR( :name<batBranch> );

sub START {
    my ($self, $ident, $args_ref) = @_;

    # Set the DOM roots and doc for the XMLs.
    my $parser = XML::LibXML->new;
    my $doc = $parser->parse_file($self->get_src_file);
    $self->set_doc($doc);
    my $src_dom = $doc->documentElement;
    my $newdoc = $parser->parse_file($self->get_tgt_file);
    my $tgt_dom = $newdoc->documentElement;

    $self->set_src_dom($src_dom);
    $self->set_tgt_dom($tgt_dom);
    $self->set_xml_schema(BuildArea::ClusterXMLCreator::XMLSchema->new);
}

=head1 INSTANCE METHODS

=over 4

=item B<< $clusterXMLCreator->create >>

Checks for various sections in XML.
Creates or merges them accordingly.

=cut

sub create {
    my ($self) = @_;

    my $schema = $self->get_xml_schema;

    # Check if there is a platforms section
    my $platform_location = $schema->get_platform;
    my @platforms_in_src = $self->get_src_dom
                                    ->find($platform_location.'/child::*')
                                        ->get_nodelist;

    if (!@platforms_in_src) {
        # Create a platform section if there is none.
        my $platform = BuildArea::ClusterXMLCreator::Platform->new({
                        src_file => $self->get_src_file,
                        tgt_file => $self->get_tgt_file,
                        src_dom => $self->get_src_dom,
                        tgt_dom => $self->get_tgt_dom,
                    });
        $platform->create;
    } else {

        # Merge platforms of the 2 XMLs.
        my @platforms = qw( unix windows);

        foreach (@platforms) {
            my $specific_platform_location =  $schema->get_specific_platform($_);

            my @platforms_in_src_file = $self->get_src_dom
                                                ->find($specific_platform_location.'/child::*')
                                                    ->get_nodelist;

            my $specific_platform = BuildArea::ClusterXMLCreator::Platform->new({
                        src_file => $self->get_src_file,
                        tgt_file => $self->get_tgt_file,
                        src_dom => $self->get_src_dom,
                        tgt_dom => $self->get_tgt_dom,
                        platform_type => $_,
                    });
            if (@platforms_in_src_file) {
                my @platforms_in_tgt_file = $self->get_tgt_dom
                                                        ->find($specific_platform_location.'/child::*')
                                                            ->get_nodelist;
                if (@platforms_in_tgt_file) {
                    $specific_platform->merge;
                }
            } else {
                $specific_platform->create;
            }
        }
    }

    # Check if the properties exist else create them
    my $properties = BuildArea::ClusterXMLCreator::Properties->new({
                        src_file => $self->get_src_file,
                        tgt_file => $self->get_tgt_file,
                        src_dom => $self->get_src_dom,
                        tgt_dom => $self->get_tgt_dom,
                    });

    my @src_file_prop = $self->get_src_dom
                                ->find('*[local-name()="properties"]')
                                  ->get_nodelist;

    if (@src_file_prop) {
        $properties->merge;
    } else {
        $properties->create;
    }

    # Set additional properties in the cluster XML
    my $settings = $self->extra_properties_from_job;

    # Add the properties to the doc.
    $self->insert_derived_properties;

    # Add the properties to the doc.
    $self->add_job_properties($settings);

    return;
}

=item B<< $clusterXMLCreator->write_cluster_xml >>

Write to a file using the DOC root.

=cut

sub write_cluster_xml {
    my ($self, $filename) = @_;

    # write the file with the combined XML
    return $self->get_doc
                    ->toFile($filename, 2);
}

=item B<< $clusterXMLCreator->extra_properties_from_job >>

Extract the properties of the job.

=cut

sub extra_properties_from_job {
    my ($self) = @_;
    my %settings;

    my $job = $self->get_job;
    # Find particular values from job SET directives
    for my $key (qw(
        TESTCOVERAGE
        COMPONENTS_TO_BUILD
    )) {
        if (my $value = $job->get_SET_dir_val($key)) {
            $settings{$key} = {
                value => $value,
                type => 'con:string',
                export => 'always',
            };
        }
    }

    # Find test stage environments from job SET directives
    # e.g. SET coverage.TestRequirement_TLAB=1
    for my $set_directive (@{$job->get_cache_dirs->{SET}}) {
        if (   $set_directive =~ /coverage\.(TestRequirement[^.]*)=(.*)/
            || $set_directive =~ /^clusterxml\.(.*)=(.*)/i
        ) {
            my $key = $1;
            my $value = $2;
            $settings{$key} = {
                value => $value,
                type => 'con:string',
                export => 'always',
            };
        }
    }
    return \%settings;
}

=item B<< $clusterXMLCreator->add_job_properties >>

Add the properties of the job to the DOM root.

=cut

sub add_job_properties {
    my ($self, $values) = @_;

    my @props = $self->get_src_dom
                        ->find($self->get_xml_schema->get_properties)
                            ->get_nodelist;

    # add comments before additional values
    BuildArea::ClusterXMLCreator::XMLElement->insertAfter(
        $props[0],
        XML::LibXML::Comment->new("\nAdditional settings from job\n")
    );

    for my $name (keys %$values) {
        my %pairs = (name => $name, %{$values->{$name}});
        my $node = $self->create_node(%pairs);
        $props[0]->appendTextNode("    ");
        $props[0]->appendChild($node);
        $props[0]->appendTextNode("\n");
    }
    $props[0]->appendTextNode("\n");
    return;
}

sub insert_derived_properties {
    my ($self) = @_;

    my $prop_node = $self->create_node(
        type => 'con:properties',
    );

    my $src_dom = $self->get_src_dom;

    BuildArea::ClusterXMLCreator::XMLElement->insertAfter($src_dom, $prop_node);

    my $location = $self->get_xml_schema->get_properties;

    my @src_file_props = $src_dom->find($location)->get_nodelist;

    my $position = $src_file_props[0];

    BuildArea::ClusterXMLCreator::XMLElement->insertAfter($position,
        XML::LibXML::Comment->new('Value derived through MW::Properties')
    );

    $self->insert_batBranch_node($position);

    return;
}

sub insert_batBranch_node {
    my ($self, $position) = @_;

    my $bat_branch = $self->get_batBranch;

    my $batBranch_node = $self->create_node(
        name => 'batBranch',  value  => $bat_branch,
        type => 'con:string', export => 'never',
    );

    BuildArea::ClusterXMLCreator::XMLElement->insertAfter($position, $batBranch_node);

    return;
}

sub create_node {
    my ($self, %pairs) = @_;
    my $type = delete $pairs{type};

    my $node = XML::LibXML::Element->new( $type );
    for my $attr (sort keys %pairs) {
        $node->setAttribute($attr, $pairs{$attr});
    }
    return $node;
}

1;
