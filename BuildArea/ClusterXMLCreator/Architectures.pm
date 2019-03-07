=head1 NAME

BuildArea::ClusterXMLCreator::Architectures - Handle create/merge of architecture section.

=head1 SYNOPSIS

    use BuildArea::ClusterXMLCreator::Architectures;
    my $architectures = BuildArea::ClusterXMLCreator::Architectures->new({
        src_file   => $src_file,
        tgt_file   => $tgt_file,
        src_dom    => $src_dom,
        tgt_dom    => $tgt_dom,
    });

    $architectures->merge;
    $architectures->create;
    $architectures->get_location;

=head1 DESCRIPTION

Module to merge or create the architectures section of Properties XMLs.

=head1 SEE ALSO

BuildArea::ClusterXMLCreator::XMLSchema;
XML::LibXML;

=cut

package BuildArea::ClusterXMLCreator::Architectures;

use strict;
use warnings;

use base qw( BuildArea::ClusterXMLCreator::XMLElement );

use Class::Std;

use XML::LibXML;

=head1 CONSTRUCTOR

=over

=item
    BuildArea::ClusterXMLCreator::Architectures->new({
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

=item B<< $architectures->merge >>

Merge the architectures sections

=cut

sub merge {
    my ($self) = @_;

    my $platform_archs_location = $self->get_location;
    my $src_dom = $self->get_src_dom;
    my $tgt_dom = $self->get_tgt_dom;

    # Return if there is no architecture in the current cluster XML
    my @tgt_file_arch_list = $tgt_dom
                                    ->find($platform_archs_location."/child::*")
                                        ->get_nodelist;
    return
        if (!@tgt_file_arch_list);

    # Find out all the architecture names for both DOMs.

    # src_file arch
    my @src_file_arch_names = $self->find_arch_names($platform_archs_location, $src_dom);

    # tgt_file archs
    my @tgt_file_arch_names = $self->find_arch_names($platform_archs_location, $tgt_dom);

    # Find the common architectures
    my @common_archs = $self->find_common(\@src_file_arch_names, \@tgt_file_arch_names);

    # Find the new architectures in the current cluster XML.
    my @new_archs = $self->diff(\@tgt_file_arch_names, \@common_archs);

    # Merge the common archs
    for my $arch (@common_archs) {
        my $arch_location = $platform_archs_location
                                .'/child::*[local-name()="architecture"]'
                                . qq{[\@name="$arch"]}
                                . '/child::*[local-name()="properties"]';

        my @src_file_archs = $src_dom->find($arch_location)->get_nodelist;

        $self->insertBefore($src_file_archs[0],
                                XML::LibXML::Comment->new("Original content from ".$self->get_src_file));

        $self->insertAfter($src_file_archs[0],
                            XML::LibXML::Comment->new("Original content from ".$self->get_tgt_file));

        for my $node ( $tgt_dom->find($arch_location."/child::*")->get_nodelist ) {
            $self->insertAfter($src_file_archs[0], $node);
        }
    }

    # Append the new ones from new DOM to the original DOM.
    for my $arch (@new_archs) {
        my @src_file_archs = $src_dom->find($platform_archs_location)->get_nodelist;

        $self->insertBefore($src_file_archs[0],
                                XML::LibXML::Comment->new("Original content from ".$self->get_src_file));

        $self->insertAfter($src_file_archs[-1],
                                XML::LibXML::Comment->new("Original content from ".$self->get_tgt_file));
        for my $node ( $tgt_dom->find($platform_archs_location
                                . '/child::*[local-name()="architecture"]'
                                . qq{[\@name="$arch"]})
                                      ->get_nodelist
                                ) {
            $self->insertAfter($src_file_archs[-1], $node);
        }
    }

    return;
}

=item B<< $architectures->create >>

Create the architectures section

=cut

sub create {
    my ($self) = @_;

    my $location = $self->get_location;
    my $schema = $self->get_xml_schema;
    my @tgt_file_archs = $self->get_tgt_dom
                                    ->find($location)->get_nodelist;
    return
        if (!@tgt_file_archs);

    my @src_file_platform = $self->get_src_dom
                                    ->find($schema->get_specific_platform($self->get_platform_type))
                                        ->get_nodelist ;

    # Insert before first node of src_parent
    $self->insertBefore($src_file_platform[0],
                        XML::LibXML::Comment->new("Original content from ".$self->get_src_file));

    for my $node ( @tgt_file_archs ) {
        $self->insertBefore($src_file_platform[0], $node);
    }

    $self->insertBefore($src_file_platform[0],
                        XML::LibXML::Comment->new("Original content from ".$self->get_tgt_file));

    return;
}

=item B<< $architectures->get_location >>

Get the location of the architectures section in XMLs.

=cut

sub get_location {
    my ($self) = @_;
    my $location;
    if ($self->get_platform_type) {
        $location = $self->get_xml_schema->get_platform_architectures($self->get_platform_type);
    }
    return $location;
}

#### HELPER FUNCTIONS ####
sub find_arch_names {
    my ($self, $location, $dom_root) = @_;

    my @arch_list = $dom_root->find($location."/child::*")->get_nodelist;
    my @arch_names;
    for my $arch (@arch_list) {
        my @attr = $arch->attributes;
        push @arch_names, $attr[0]->value;
    }
    return @arch_names;
}

sub find_common {
    my ($self, $arr1, $arr2) = @_;
    my %seen = map { $_ => 1} @$arr2;
    return grep {exists($seen{$_})} @$arr1;
}

# $arr1 - $arr2
sub diff {
    my ($self, $arr1, $arr2) = @_;
    my %common = map { $_ => 1} @$arr2;
    return grep {!exists($common{$_})} @$arr1;
}

1;
