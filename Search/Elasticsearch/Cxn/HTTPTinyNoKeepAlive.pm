package Search::Elasticsearch::Cxn::HTTPTinyNoKeepAlive;
$Search::Elasticsearch::Cxn::HTTPTinyNoKeepAlive::VERSION = '5.02';

use base qw(Search::Elasticsearch::Cxn::HTTPTiny);
use HTTP::Tiny 0.043 ();

#===================================
sub _build_handle {
#===================================
    my $self = shift;
    my %args = ( default_headers => $self->default_headers, keep_alive => 0 );
    if ( $self->is_https && $self->has_ssl_options ) {
        $args{SSL_options} = $self->ssl_options;
        if ( $args{SSL_options}{SSL_verify_mode} ) {
            $args{verify_ssl} = 1;
        }
    }

    return HTTP::Tiny->new( %args, %{ $self->handle_args } );
}

1;

=head1 AUTHOR

Clinton Gormley <drtech@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2017 by Elasticsearch BV.

This is free software, licensed under:

  The Apache License, Version 2.0, January 2004

=cut
