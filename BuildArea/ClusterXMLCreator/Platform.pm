=head1 NAME

BuildArea::ClusterXMLCreator::Platform - Handle create/merge of platform section.

=head1 SYNOPSIS

    use BuildArea::ClusterXMLCreator::Platform;
    my $platform = BuildArea::ClusterXMLCreator::Platform->new({
        src_file   => $src_file,
        tgt_file   => $tgt_file,
        src_dom    => $src_dom,
        tgt_dom    => $tgt_dom,
    });

    $platform->merge;
    $platform->create;
    $platform->get_location;

=head1 DESCRIPTION

Module to merge or create the Platforms section of XMLs.

=head1 SEE ALSO

BuildArea::ClusterXMLCreator::Properties;
BuildArea::ClusterXMLCreator::Architectures;
BuildArea::ClusterXMLCreator::XMLSchema;
XML::LibXML;

=cut

package BuildArea::ClusterXMLCreator::Platform;

use strict;
use warnings;

use base qw( BuildArea::ClusterXMLCreator::XMLElement );

use Class::Std;

use XML::LibXML;

use BuildArea::ClusterXMLCreator::Properties;
use BuildArea::ClusterXMLCreator::Architectures;

=head1 CONSTRUCTOR

=over

=item
    BuildArea::ClusterXMLCreator::Platform->new({
        src_file   => $src_file,
        tgt_file   => $tgt_file,
        src_dom    => $src_dom,
        tgt_dom    => $tgt_dom,
    });

Use $src_file as the path of the cluster XML we are cloning from.

Use $tgt_file as the path of the current cluster XML.

use $src_dom as the dom root after parsing the clone cluster XML.

use $tgt_dom as the dom root after parsing the current cluster XML.

=back

=head1 INSTANCE METHODS

=over 4

=item B<< $platform->merge >>

Merge the Platforms

=cut

sub merge {
    my ($self) = @_;

    my $schema = $self->get_xml_schema;

    # Merge/Create Architectures
    my $platform_archs_location = $schema->get_platform_architectures($self->get_platform_type);
    my @src_file_platform_archs = $self->get_src_dom
                                            ->find($platform_archs_location.'/child::*')
                                                ->get_nodelist;

    my $architectures = BuildArea::ClusterXMLCreator::Architectures->new({
                            src_file => $self->get_src_file,
                            tgt_file => $self->get_tgt_file,
                            src_dom => $self->get_src_dom,
                            tgt_dom => $self->get_tgt_dom,
                            platform_type => $self->get_platform_type,
                        });
    if (@src_file_platform_archs) {
        $architectures->merge($schema->get_platform_architectures($self->get_platform_type)); # Change this
    } else {
        $architectures->create;
    }

    # Handle platform properties
    my $platform_gen_prop_location = $schema->get_platform_properties($self->get_platform_type);
    my @platform_gen_props_in_src_file = $self->get_src_dom
                                                ->find($platform_gen_prop_location.'/child::*')
                                                    ->get_nodelist;

    my $platform_properties = BuildArea::ClusterXMLCreator::Properties->new({
                        src_file => $self->get_src_file,
                        tgt_file => $self->get_tgt_file,
                        src_dom => $self->get_src_dom,
                        tgt_dom => $self->get_tgt_dom,
                        platform_type => $self->get_platform_type,
                    });

    if (@platform_gen_props_in_src_file) {
        $platform_properties->merge;
    } else {
        $platform_properties->create;
    }

    return;
}

=item B<< $platform->create >>

Create the Platforms section

=cut

sub create {
    my ($self) = @_;

    my $location = $self->get_location;
    my $schema = $self->get_xml_schema;
    my @tgt_file_nodes = $self->get_tgt_dom
                                    ->find($location)
                                        ->get_nodelist;
    return
        if (!@tgt_file_nodes);

    my $src_dom = $self->get_src_dom;

    if ($self->get_platform_type) {
        my @src_file_platform = $src_dom->find($schema->get_platform)->get_nodelist;

        if ($self->get_platform_type eq 'unix') {
            # Insert before first node of src_file_platform
            $self->insertBefore($src_file_platform[0],
                        XML::LibXML::Comment->new("Original content from ".$self->get_src_file));

            for my $node ( @tgt_file_nodes ) {
                $self->insertBefore($src_file_platform[0], $node);
            }

            $self->insertBefore($src_file_platform[0],
                        XML::LibXML::Comment->new("Original content from ".$self->get_tgt_file));

        } else {
            # Insert after first node of src_file_platform
            $self->insertBefore($src_file_platform[0],
                        XML::LibXML::Comment->new("Original content from ".$self->get_src_file));

            $self->insertAfter($src_file_platform[0],
                        XML::LibXML::Comment->new("Original content from ".$self->get_tgt_file));
            for my $node ( @tgt_file_nodes ) {
                $self->insertAfter($src_file_platform[0], $node);
            }
        }
    } else {
        for my $node ( @tgt_file_nodes ) {
            $self->insertBefore($src_dom, $node);
        }

        $self->insertBefore($src_dom,
                        XML::LibXML::Comment->new("Original content from ".$self->get_tgt_file));
    }
    return;
}

=item B<< $platform->get_location >>

Get location of the platforms section in XML.

=cut

sub get_location {
    my ($self) = @_;
    my $location;
    if ($self->get_platform_type) {
        $location = $self->get_xml_schema->get_specific_platform($self->get_platform_type);
    } else {
        $location = $self->get_xml_schema->get_platform;
    }
    return $location;
}

1;
