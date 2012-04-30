package CHI::Memoize;
use Memoize::Info;
use strict;
use warnings;

my %memoized;
my @get_set_options = ( CHI->valid_get_options, CHI->valid_set_options );
my %is_get_set_option = map { ( $_, 1 ) } @get_set_options;

sub memoize {
    my ( $func, %options ) = @_;

    my ( $func_name, $func_ref, $func_id ) = _parse_func_arg($func);
    croak "'$func_id' is already memoized" if exists( $memoized{$func_id} );

    my $passed_key      = delete( $options{key} );
    my $cache           = delete( $options{cache} );
    my %compute_options = slice_grep { $is_get_set_option{$_} } \%options;
    if ( !$cache ) {
        my %cache_options = slice_grep { !$is_get_set_option{$_} } \%options;
        $cache_options{namespace} ||= "memoize-$func_id";
        $cache = CHI->new(%cache_options);
    }

    my $wrapper = sub {
        my $wantarray = wantarray ? 'L' : 'S';
        my @key_parts =
          defined($passed_key)
          ? ( ( ref($passed_key) eq 'CODE' ) ? $passed_key->(@_) : ($passed_key) )
          : @_;
        my $key = [ "memoize-$func_id-$wantarray", @key_parts ];
        return $cache->compute( $key, \%compute_options, $func_ref );
    };
    $memoized{$func_id} =
      Memoize::Info->new( orig => $func_ref, wrapper => $wrapper, cache => $cache );
    *{$func_name} = $wrapper if $func_name;

    return $wrapper;
}

sub unmemoize {
    my ( $func_name, $func_ref, $func_id ) = _parse_func_arg( $_[0] );
    my $info = $memoized{$func_id} or die "$func_id is not memoized";

    eval { $info->cache->clear() };
    *{$func_name} = $info->orig if $func_name;
    return $info->orig;
}

sub _parse_func_arg {
    my ($func) = @_;
    my ( $func_name, $func_ref, $func_id );
    if ( ref($func) eq 'CODE' ) {
        $func_ref = $func;
        $func_id  = "$func_ref";
    }
    else {
        $func_name = caller() . "::$name" if $func_name !~ /::/;
        $func_id   = $func_name;
        $func_ref  = *{$func_name};
        die "no such function '$func_name'" if ref($func_ref) ne 'CODE';
    }
    return ( $func_name, $func_ref, $func_id );
}

1;

__END__

=pod

=head1 NAME

CHI::Memoize - Make functions faster with memoization, via CHI

=head1 SYNOPSIS

    use CHI::Memoize;

    # Straight memoization in memory
    memoize('func');
    memoize('Some::Package::func');
  
    # Memoize an anonymous function
    $anon = memoize($anon);

    # Memoize based on the second and third argument to func
    memoize('func', key => sub { [$_[1], $_[2]] });
    
    # Expire after one hour
    memoize('func', expires_in => '1h');
    
    # Store a maximum of 10 results with LRU discard
    memoize('func', max_size => 10);
    
    # Store in memcached instead of memory
    memoize('func', driver => 'Memcached', servers => ["127.0.0.1:11211"]);

    # See what's been memoized for a function
    my @keys = memoized('func')->cache->get_keys;

    # Clear memoize results for a function
    my @keys = memoized('func')->cache->clear;

    # Use an explicit cache instead of autocreating one
    my $cache = CHI->new(driver => 'Memcached', servers => ["127.0.0.1:11211"]);
    memoize('func', cache => $cache);

    # Unmemoize function, restoring it to its original state
    unmemoize('func');

=head1 DESCRIPTION

C<CHI::Memoize> provides the same facility as L<Memoize|Memoize>, but backed by
L<CHI|CHI>. This means you can specify expiration times and conditions, memoize
to different backends (file, memcached, DBI, etc.), etc.

From C<Memoize>:

     `Memoizing' a function makes it faster by trading space for
     time.  It does this by caching the return values of the
     function in a table.  If you call the function again with
     the same arguments, ""memoize"" jumps in and gives you the
     value out of the table, instead of letting the function
     compute the value all over again.

=head2 METHODS

=for html <a name="memoize">

=over

=item memoize ($func, option =E<gt> value, ...)

Creates a new function wrapped around I<$func> that caches results based on
passed arguments.

I<$func> can be a function name (with or without a package prefix), or an
anonymous function. In the former case, the name is rebound to the new
function. In either case a code ref to the new function is returned.

By default, the cache key is formed from combining all the arguments with JSON
in canonical mode (sorted hash keys). e.g. these arguments will generate the
same cache key:

    memoized_function(a => 5, b => 6, c => { d => 7, e => 8 });
    memoized_function(b => 6, c => { e => 8, d => 7 }, a => 5);

By default, the cache L<namespace|CHI/namespace> is formed from the full
function name or the stringified code reference.  This allows you to introspect
and clear the memoized results for a particular function.

List and scalar context results are memoized separately, so these results will
not interfere even though they have the same function name and arguments:

     my $scalar = memoized_function(5);
     my @list = memoized_function(5);

=item memoized ($func)

Returns a L<CHI::Memoize::Info|CHI::Memoize::Info> object if I<$func> has been
memoized, or undef if it has not been memoized.

    # The CHI cache where memoize results are stored
    #
    my $cache = memoized($func)->cache;
    $cache>clear;

    # The original function, and the new wrapped function
    #
    my $orig = memoized($func)->orig;
    my $wrapped = memoized($func)->wrapped;

=item unmemoize ($func)

Removes the wrapper around I<$func>, restoring it to its original unmemoized
state.  Also clears the memoize cache if possible (not supported by all
drivers, particularly L<memcached|CHI::Driver::Memcached>). Throws an error if
I<$func> has not been memoized.

=back

=head2 OPTIONS

The following options can be passed to L<memoize>.

=over

=item key

Specifies a code reference that takes arguments passed to the function and
returns the key. The key may be returned as a list or a hash reference; it will
automatically be serialized to JSON in canonical mode (sorted hash keys). e.g.
this is the uses the second and third argument to the function as a key:

    memoize('func', key => sub { @_[1..2] });

=item set and get options

You can pass any options accepted by CHI's L<set|CHI/set> (e.g. C<expires_in>,
C<expires_variance>) or L<get|CHI/get> (e.g. C<expire_if>, C<busy_lock>). e.g.

    # Expire after one hour
    memoize('func', expires_in => '1h');
    
    # Expire when a particular condition occurs
    memoize('func', expire_if => sub { ... });

=item cache options

You can specify options to C<< CHI->new >> to generate the cache:

    # Store in memcached instead of memory
    memoize('func', driver => 'Memcached', servers => ["127.0.0.1:11211"]);

Unless specified, the L<namespace|CHI/namespace> is generated from the full
name of the function being memoized.

You can also specify an existing cache object:

    # Store in memcached instead of memory
    my $cache = CHI->new(driver => 'Memcached', servers => ["127.0.0.1:11211"]);
    memoize('func', cache => $cache);

=back

=head1 SUPPORT

Questions and feedback are welcome, and should be directed to the perl-cache
mailing list:

    http://groups.google.com/group/perl-cache-discuss

Bugs and feature requests will be tracked at RT:

    http://rt.cpan.org/NoAuth/Bugs.html?Dist=CHI-Memoize
    bug-chi-memoize@rt.cpan.org

The latest source code can be browsed and fetched at:

    http://github.com/jonswar/perl-chi-memoize
    git clone git://github.com/jonswar/perl-chi-memoize.git

=head1 SEE ALSO

L<Some::Module>

