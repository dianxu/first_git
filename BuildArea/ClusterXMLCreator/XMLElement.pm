=head1 NAME

BuildArea::ClusterXMLCreator::XMLElement - Base class for each section of XML.

=head1 SYNOPSIS

    use BuildArea::ClusterXMLCreator::XMLElement;
    my $element = BuildArea::ClusterXMLCreator::XMLElement->new({
        src_file               => $src_file,
        tgt_file               => $tgt_file,
        src_dom                => $src_dom,
        tgt_dom                => $tgt_dom,
    });

    $element->create;
    $element->merge;
    $element->get_location;

=head1 DESCRIPTION

Base module for an element in the XML.

=cut

package BuildArea::ClusterXMLCreator::XMLElement;

use strict;
use warnings;

use Class::Std;

use XML::LibXML;

=head1 CONSTRUCTOR

=over

=item
    BuildArea::ClusterXMLCreator::XMLElement->new({
        src_file               => $src_file,
        tgt_file               => $tgt_file,
        src_dom                => $src_dom,
        tgt_dom                => $tgt_dom,

    });

Use $src_file as the path of the cluster XML we are cloning from. This should not be undef.

Use $tgt_file as the path of the current cluster XML. This should not be undef.

use $src_dom as the dom root after parsing the clone cluster XML. This should not be undef.

use $tgt_dom as the dom root after parsing the current cluster XML. This should not be undef.

=back

=head1 Constructor Arguments ACCESSOR METHODS

=over 4

=cut

=item B<< $element->get_src_file >>

Path of clone cluster XML.

=item B<< $element->get_tgt_file >>

Path of the current cluster XML.

=item B<< $element->get_src_dom >>

DOM root of clone cluster XML.

=item B<< $element->get_tgt_dom >>

DOM root of current cluster XML.

=item B<< $element->get_xml_schema >>

XMLSchema object to obtain the location of various
elements in XML.

=item B<< $element->get_platform_type >>

Returns Platform type (either unix or windows).
Undef if it is a generic element.

=cut

my %src_file_of      : ATTR( :name<src_file> );
my %tgt_file_of      : ATTR( :name<tgt_file> );
my %src_dom_of       : ATTR( :name<src_dom>   );
my %tgt_dom_of      : ATTR( :name<tgt_dom> );
my %platform_type_of : ATTR( :name<platform_type> :default<> );
my %xml_schema_of    : ATTR( :name<xml_schema>    :default<> );

sub START {
    my ($self, $ident, $args_ref) = @_;

    $self->set_xml_schema(BuildArea::ClusterXMLCreator::XMLSchema->new);
    return;
}

=back

=head1 INSTANCE METHODS

=over 4

=item B<< $element->merge >>

Merge the elements

=cut

sub merge {
    my ($self) = @_;
    return;
}

=item B<< $element->create >>

Create the elements

=cut

sub create {
    my ($self) = @_;
    return;
}

=item B<< $element->get_location >>

Get the location of the elements

=cut

sub get_location {
    my ($self) = @_;
    return;
}

=item B<< $element->insertBefore >>

Insert a node before an element.

=cut
sub insertBefore {
    my ($self, $element, $node) = @_;
    $element->insertBefore(XML::LibXML::Text->new("\n"), $element->firstChild);
    $element->insertBefore($node, $element->firstChild);
    $element->insertBefore(XML::LibXML::Text->new("\n"), $element->firstChild);
    return $element;
}

=item B<< $element->insertAfter >>

Insert a node after an element.

=cut

sub insertAfter {
    my ($self, $element, $node) = @_;
    $element->appendTextNode("\n");
    $element->appendChild($node);
    $element->appendTextNode("\n");
    return;
}

1;
