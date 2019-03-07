=head1 NAME

BuildArea::ClusterXMLCreator::Properties - Handle create/merge of properties section.

=head1 SYNOPSIS

    use BuildArea::ClusterXMLCreator::Properties;
    my $properties = BuildArea::ClusterXMLCreator::Properties->new({
        src_file               => $src_file,
        tgt_file             => $tgt_file,
        src_dom      => $src_dom,
        tgt_dom    => $tgt_dom,
    });

    $properties->merge;
    $properties->create;
    $properties->get_location;

=head1 DESCRIPTION

Module to merge or create the properties section of XMLs.

=head1 SEE ALSO

BuildArea::ClusterXMLCreator::XMLSchema;
XML::LibXML;

=cut

package BuildArea::ClusterXMLCreator::Properties;

use strict;
use warnings;

use base qw( BuildArea::ClusterXMLCreator::XMLElement );

use Class::Std;
use XML::LibXML;

=head1 CONSTRUCTOR

=over

=item
    BuildArea::ClusterXMLCreator::Properties->new({
        src_file               => $src_file,
        tgt_file             => $tgt_file,
        src_dom      => $src_dom,
        tgt_dom    => $tgt_dom,
    });

Use $src_file as the path of the cluster XML we are cloning from.

Use $tgt_file as the path of the current cluster XML.

use $src_dom as the dom root after parsing the clone cluster XML.

use $tgt_dom as the dom root after parsing the current cluster XML.

=back

=head1 INSTANCE METHODS

=over 4

=item B<< $properties->merge >>

Merge the properties sections

=cut

sub merge {
    my ($self) = @_;

    my $location = $self->get_location;
    my @src_file_props = $self->get_src_dom
                               ->find($location)->get_nodelist;

    if (@src_file_props) {

        my @tgt_file_props = $self->get_tgt_dom
                                        ->find($location.'/child::*')->get_nodelist;

        $self->insertBefore($src_file_props[0],
                                XML::LibXML::Comment->new("Original content from ".$self->get_src_file));

        $self->insertAfter($src_file_props[0],
                        XML::LibXML::Comment->new("Original content from ".$self->get_tgt_file));

        for my $node ( @tgt_file_props ) {
            $self->insertAfter($src_file_props[0], $node);
        }
    } else {

        $self->create;
    }

    return;
}

=item B<< $properties->create >>

Create the properties section

=cut

sub create {
    my ($self) = @_;

    my $location = $self->get_location;
    my @tgt_file_props = $self->get_tgt_dom
                                    ->find($location)->get_nodelist;

    my $src_dom = $self->get_src_dom;

    if ($self->get_platform_type) {
        my @src_file_platform_prop = $src_dom->find('*[local-name()="platforms"]'
                                        .'/child::*[local-name()="'.$self->get_platform_type.'"]')
                                            ->get_nodelist;

        $self->insertBefore($src_file_platform_prop[0],
                        XML::LibXML::Comment->new("Original content from ".$self->get_src_file));

        $self->insertAfter($src_file_platform_prop[0],
                        XML::LibXML::Comment->new("Original content from ".$self->get_tgt_file));

        for my $node ( @tgt_file_props ) {
            $self->insertAfter($src_file_platform_prop[0], $node);
        }
    } else {
        $self->insertAfter($src_dom,
                        XML::LibXML::Comment->new("Original content from ".$self->get_tgt_file));
        for my $node ( @tgt_file_props ) {
            $self->insertAfter($src_dom, $node);
        }

    }

    return;
}




=item B<< $properties->get_location >>

Get the location of properties section in the XML.

=cut

sub get_location {
    my ($self) = @_;
    my $location;
    if ($self->get_platform_type) {
        $location = $self->get_xml_schema->get_platform_properties($self->get_platform_type);
    } else {
        $location = $self->get_xml_schema->get_properties;
    }
    return $location;
}

1;
