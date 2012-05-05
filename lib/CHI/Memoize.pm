package CHI::Memoize;
use Carp;
use CHI;
use CHI::Memoize::Info;
use CHI::Driver;
use Hash::MoreUtils qw(slice_grep);
use strict;
use warnings;
use base qw(Exporter);

our @EXPORT      = qw(memoize);
our @EXPORT_OK   = qw(memoize memoized unmemoize);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

my %memoized;
my @get_set_options = qw( busy_lock expire_if expires_at expires_in expires_variance );
my %is_get_set_option = map { ( $_, 1 ) } @get_set_options;

sub memoize {
    my ( $func, %options ) = @_;

    my ( $func_name, $func_ref, $func_id ) = _parse_func_arg( $func, scalar(caller) );
    croak "'$func_id' is already memoized" if exists( $memoized{$func_id} );

    my $passed_key      = delete( $options{key} );
    my $cache           = delete( $options{cache} );
    my %compute_options = slice_grep { $is_get_set_option{$_} } \%options;
    my $prefix          = "memoize::$func_id";

    if ( !$cache ) {
        my %cache_options = slice_grep { !$is_get_set_option{$_} } \%options;
        $cache_options{namespace} ||= $prefix;
        if ( !$cache_options{driver} && !$cache_options{driver_class} ) {
            $cache_options{driver} = "Memory";
            $cache_options{global} = 1;
        }
        $cache = CHI->new(%cache_options);
    }

    my $wrapper = sub {
        my $wantarray = wantarray ? 'L' : 'S';
        my @key_parts =
          defined($passed_key)
          ? ( ( ref($passed_key) eq 'CODE' ) ? $passed_key->(@_) : ($passed_key) )
          : @_;
        my $key = [ $prefix, $wantarray, @key_parts ];
        return $cache->compute( $key, {%compute_options}, $func_ref );
    };
    $memoized{$func_id} = CHI::Memoize::Info->new(
        orig       => $func_ref,
        wrapper    => $wrapper,
        cache      => $cache,
        key_prefix => $prefix
    );

    no strict 'refs';
    no warnings 'redefine';
    *{$func_name} = $wrapper if $func_name;

    return $wrapper;
}

sub memoized {
    my ( $func_name, $func_ref, $func_id ) = _parse_func_arg( $_[0], scalar(caller) );
    return $memoized{$func_id};
}

sub unmemoize {
    my ( $func_name, $func_ref, $func_id ) = _parse_func_arg( $_[0], scalar(caller) );
    my $info = $memoized{$func_id} or die "$func_id is not memoized";

    eval { $info->cache->clear() };
    no strict 'refs';
    no warnings 'redefine';
    *{$func_name} = $info->orig if $func_name;
    delete( $memoized{$func_id} );
    return $info->orig;
}

sub _parse_func_arg {
    my ( $func, $caller ) = @_;
    my ( $func_name, $func_ref, $func_id );
    if ( ref($func) eq 'CODE' ) {
        $func_ref = $func;
        $func_id  = "$func_ref";
    }
    else {
        $func_name = $func;
        $func_name = join( "::", $caller, $func_name ) if $func_name !~ /::/;
        $func_id   = $func_name;
        no strict 'refs';
        $func_ref = \&$func_name;
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

    use CHI::Memoize qw(:all);
    
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

"`Memoizing' a function makes it faster by trading space for time.  It does
this by caching the return values of the function in a table.  If you call the
function again with the same arguments, C<memoize> jumps in and gives you the
value out of the table, instead of letting the function compute the value all
over again." -- quoted from the original L<Memoize|Memoize>

C<CHI::Memoize> provides the same facility as L<Memoize|Memoize>, but backed by
L<CHI|CHI>. This means, among other things, that you can

=over

=item *

specify expiration times (L<expires_in|CHI/expires_in>) and conditions
(L<expire_if|CHI/expire_if>)

=item *

memoize to different backends, e.g. L<File|CHI::Driver::File>,
L<Memcached|CHI::Driver::Memcached>, L<DBI|CHI::Driver::DBI>, or to
L<multilevel caches|CHI/SUBCACHES>

=item *

handle arbitrarily complex function arguments (via CHI L<key
serialization|CHI/Key transformations>)

=back

=head2 FUNCTIONS

All of these are importable; only C<memoize> is imported by default. C<use
Memoize qw(:all)> will import them all.

=for html <a name="memoize">

=over

=item memoize ($func, option =E<gt> value, ...)

Creates a new function wrapped around I<$func> that caches results based on
passed arguments.

I<$func> can be a function name (with or without a package prefix) or an
anonymous function. In the former case, the name is rebound to the new
function. In either case a code ref to the new wrapper function is returned.

By default, the cache key is formed from combining the full function name, the
calling context ("L" or "S"), and all the function arguments with canonical
JSON (sorted hash keys). e.g. these arguments will generate the same cache key:

    memoized_function(a => 5, b => 6, c => { d => 7, e => 8 });
    memoized_function(b => 6, c => { e => 8, d => 7 }, a => 5);

but these will use a different cache key because of context:

     my $scalar = memoized_function(5);
     my @list = memoized_function(5);

By default, the cache L<namespace|CHI/namespace> is formed from the full
function name or the stringified code reference.  This allows you to introspect
and clear the memoized results for a particular function.

C<memoize> throws an error if I<$func> is already memoized.

=item memoized ($func)

Returns a L<CHI::Memoize::Info|CHI::Memoize::Info> object if I<$func> has been
memoized, or undef if it has not been memoized.

    # The CHI cache where memoize results are stored
    #
    my $cache = memoized($func)->cache;
    $cache->clear;

    # Code references to the original function and to the new wrapped function
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

The following options can be passed to L</memoize>.

=over

=item key

Specifies a code reference that takes arguments passed to the function and
returns a cache key. The key may be returned as a list, list reference or hash
reference; it will automatically be serialized to JSON in canonical mode
(sorted hash keys).  e.g.  this uses the second and third argument to the
function as a key:

    memoize('func', key => sub { @_[1..2] });

Regardless of what key you specify, it will automatically be prefixed with the
full function name and the calling context ("L" or "S").

=item set and get options

You can pass any of CHI's L<set|CHI/set> options (e.g.
L<expires_in|CHI/expires_in>, L<expires_variance|CHI/expires_variance>) or
L<get|CHI/get> options (e.g. L<expire_if|CHI/expire_if>,
L<busy_lock|CHI/busy_lock>). e.g.

    # Expire after one hour
    memoize('func', expires_in => '1h');
    
    # Expire when a particular condition occurs
    memoize('func', expire_if => sub { ... });

=item cache options

Any remaining options will be passed to the L<CHI constructor|CHI/CONSTRUCTOR>
to generate the cache:

    # Store in memcached instead of memory
    memoize('func', driver => 'Memcached', servers => ["127.0.0.1:11211"]);

Unless specified, the L<namespace|CHI/namespace> is generated from the full
name of the function being memoized.

You can also specify an existing cache object:

    # Store in memcached instead of memory
    my $cache = CHI->new(driver => 'Memcached', servers => ["127.0.0.1:11211"]);
    memoize('func', cache => $cache);

=back

=head1 RELATED MODULES

A number of modules address a subset of the problems addressed by this module,
including:

=over

=item *

L<Memoize::Expire> - pluggable expiration of memoized values

=item *

L<Memoize::ExpireLRU> - provides LRU expiration for Memoize

=item *

L<Memoize::Memcached> - use a memcached cache to memoize functions

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

L<CHI|CHI>, L<Memoize|Memoize>

