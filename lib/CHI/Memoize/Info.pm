package CHI::Memoize::Info;
use Moose;
use strict;
use warnings;

has [ 'orig', 'wrapper', 'cache', 'key_prefix' ] => ( is => 'ro' );

1;

__END__

=pod

=head1 NAME

CHI::Memoize::Info - Information about a memoized function

=head1 SYNOPSIS

    use CHI::Memoize;

    my $info = memoized('func');
    
    # The CHI cache where memoize results are stored
    #
    my $cache = $info->cache;
    $cache>clear;

    # The original function, and the new wrapped function
    #
    my $orig = $info->orig;
    my $wrapped = $info->wrapped;
