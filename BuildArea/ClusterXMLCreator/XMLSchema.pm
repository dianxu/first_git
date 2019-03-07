=head1 NAME

BuildArea::ClusterXMLCreator::XMLSchema - Returns locations of various sections in XML.

=head1 SYNOPSIS

    use BuildArea::ClusterXMLCreator::XMLSchema;
    my $schema = BuildArea::ClusterXMLCreator::XMLSchema->new;

    $schema->get_platform;
    $schema->get_specific_platform($platform);
    $schema->get_platform_architectures($platform);
    $schema->get_platform_properties($platform);
    $schema->get_properties;

=head1 DESCRIPTION

Module to obtain location of various sections of XMLs.

=cut

package BuildArea::ClusterXMLCreator::XMLSchema;

use strict;
use warnings;

use Class::Std;

sub get_platform {
    my ($self) = @_;
    return '*[local-name()="platforms"]';
}

sub get_specific_platform {
    my ($self, $platform) = @_;
    return '*[local-name()="platforms"]'
            . '/child::*[local-name()="'.$platform.'"]';
}

sub get_platform_architectures {
    my ($self, $platform) = @_;
    return '*[local-name()="platforms"]'
        . '/child::*[local-name()="'.$platform.'"]'
        . '/child::*[local-name()="architectures"]';
}

sub get_platform_properties {
    my ($self, $platform) = @_;
    return '*[local-name()="platforms"]'
        . '/child::*[local-name()="'.$platform.'"]'
        . '/child::*[local-name()="properties"]';
}

sub get_properties {
    my ($self) = @_;
    return '*[local-name()="properties"]';
}

1;