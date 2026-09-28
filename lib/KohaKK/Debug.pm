package KohaKK::Debug;
use warnings; use strict; use 5.16.0;

use Time::HiRes ();
use JSON        ();
use Data::Dumper ();

###########################
our $VERSION = '0.0.1';

###########################
my $glob_warn   = $SIG{__WARN__};
my $my_warn     = \&mywarn;

sub get_callers
{
    my $start = shift // 1;
    my $depth = shift || 10;

    my @stack;
    for( my $i = $start; $i < $depth; $i++ ) {
        my @c = caller($i);

        if( ! @c ) {
            last;
        }
        else {
            my ($package,   $filename, $line,       $subroutine, $hasargs,
                $wantarray, $evaltext, $is_require, $hints,      $bitmask,
                $hinthash
               )
                = @c;

            push @stack, [$subroutine, $package, $filename, $line];
        }
    }

    my $l = "CALLERS:\n";
    my $i = $start;
    foreach my $c (@stack) {
        $l .= sprintf(
            qq~  $i: %s in %s, from %s:%d\n~,
            $c->[0] // '-undef-', $c->[1] // '-undef-', $c->[2] // '-undef-', $c->[3] // '-undef-',
        );
        $i++;
    }
    return $l;
}

sub mywarn { my $l = get_callers(2); local $SIG{__WARN__} = $glob_warn; warn(@_, $l); }

sub _h
{
    my $s = shift // '';
    $s =~ s/>/&gt;/g;
    $s =~ s/</&lt;/g;
    return $s;
}

sub dumper
{
    my $var   = shift;
    my $name  = shift;
    my $dense = shift || 0;
    my $depth = shift || 0;
    my $s     = Data::Dumper->new( $var, $name )->Sortkeys(
        sub {
            return [sort { lc $a cmp lc $b } keys %{ $_[0] }];
        } )->Maxdepth($depth)->Indent( $dense ? 0 : 1 )->Purity(0)->Deepcopy(1)->Dump;  # Deparse(1)
    return $s;
}

sub Dump
{
    my $p_vars  = [];
    my $p_names = [];
    my @texts;

    if( ref $_[0] eq 'ARRAY' ) {
        $p_vars  = shift;
        $p_names = shift if ref $_[0] eq 'ARRAY';
    }
    else {
        push @texts, shift if not ref $_[0];
        if( ref $_[0] eq 'HASH' ) {
            my $p_hash = shift;
            foreach my $k ( sort keys %$p_hash ) {
                push @$p_names, $k;
                push @$p_vars,  $p_hash->{$k};
            }
        }
        else {
            warn "What you are doing here?";
        }
    }

    my $dump_depth    = shift;
    my $dump_dense    = shift;
    my $callers_level = shift;
    my $callers_depth = shift;

    for (my $i = 0; $i < @$p_vars; $i++) {
        push @texts, dumper( [$p_vars->[$i]], [$p_names->[$i]], $dump_dense, $dump_depth );
    }

    return join "\n", @texts, ( $callers_level ? get_callers($callers_level, $callers_depth) . "\n" : '' );
}

1;
