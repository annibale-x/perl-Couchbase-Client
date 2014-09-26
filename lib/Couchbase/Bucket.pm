package Couchbase::Bucket;

use strict;
use warnings;

use JSON;
use URI;
use Storable;

use Couchbase;
use Couchbase::_GlueConstants;
use Couchbase::Document;
use Couchbase::Settings;
use Couchbase::OpContext;
use Couchbase::View::Handle;
use Couchbase::View::HandleInfo;

my $_JSON = JSON->new()->allow_nonref;
sub _js_encode { $_JSON->encode($_[0]) }
sub _js_decode { $_JSON->decode($_[0]) }

sub new {
    my ($pkg, $connstr, $opts) = @_;
    my %options = ($opts ? %$opts : ());

    if (ref $connstr eq 'HASH') {
        %options = (%options, %$connstr);
    } else {
        $options{connstr} = $connstr;
    }

    die "Must have connection string" unless $options{connstr};
    my $self = $pkg->construct(\%options);

    $self->connect();
    $self->_set_converters(CONVERTERS_JSON, \&_js_encode, \&_js_decode);
    $self->_set_converters(CONVERTERS_STORABLE, \&Storable::freeze, \&Storable::thaw);
    return $self;
}

sub __statshelper {
    my ($doc, $server, $key, $value) = @_;
    if (!$doc->value || ref $doc->value ne 'HASH') {
        $doc->value({});
    }
    ($doc->value->{$server} ||= {})->{$key} = $value;
}

sub _dispatch_stats {
    my ($self, $mname, $key, $options, $ctx) = @_;
    my $doc;

    if (ref $key eq 'Couchbase::Document') {
        $doc = $key;
    } else {
        $doc = Couchbase::StatsResult->new($key || "");
    }

    {
        no strict 'refs';
        $self->$mname($doc, $options, $ctx);
    }

    return $doc;
}

sub stats {
    my ($self, @args) = @_;
    $self->_dispatch_stats("_stats", @args);
}

sub keystats {
    my ($self, @args) = @_;
    $self->_dispatch_stats("_keystats", @args);
}

sub transform {
    my ($self, $doc, $xfrm) = @_;
    my $tmo = $self->settings()->{operation_timeout} / 1_000_000;
    my $now = time();
    my $end = $now + $tmo;

    while ($now < $end) {
        # Try to perform the mutation
        my $rv = $xfrm->(\$doc->value);

        if (!$rv) {
            last;
        }

        $self->replace($doc);

        if ($doc->is_cas_mismatch) {
            $self->get($doc);
        } else {
            last;
        }
    }

    return $doc;
}

sub transform_id {
    my ($self, $id, $xfrm) = @_;
    my $doc = Couchbase::Document->new($id);
    $self->get($doc);
    return $self->transform($doc, $xfrm);
}

sub settings {
    my $self = shift;
    tie my %h, 'Couchbase::Settings', $self;
    return \%h;
}

# Returns a 'raw' request handle
sub _htraw {
    my $self = $_[0];
    return $self->_new_viewhandle(\%Couchbase::View::Handle::RawIterator::);
}

# Gets a design document
sub design_get {
    my ($self,$path) = @_;
    my $handle = $self->_new_viewhandle(\%Couchbase::View::Handle::Slurpee::);
    my $design = $handle->slurp_jsonized("GET", "_design/" . $path, "");
    bless $design, 'Couchbase::View::Design';
}

# saves a design document
sub design_put {
    my ($self,$design,$path) = @_;
    if (ref $design) {
        $path = $design->{_id};
        $design = encode_json($design);
    }
    my $handle = $self->_new_viewhandle(\%Couchbase::View::Handle::Slurpee::);
    return $handle->slurp_jsonized("PUT", $path, $design);
}

sub _process_viewpath_common {
    my ($orig,%options) = @_;
    my %qparams;
    if (%options) {
        # TODO: pop any other known parameters?
        %qparams = (%qparams,%options);
    }

    if (ref $orig ne 'ARRAY') {
        if (!$orig) {
            die("Path cannot be empty");
        }
        $orig = [($orig =~ m,([^/]+)/(.*),)]
    }

    unless ($orig->[0] && $orig->[1]) {
        die("Path cannot be empty");
    }

    # Assume this is an array of [ design, view ]
    $orig = sprintf("_design/%s/_view/%s", @$orig);

    if (%qparams) {
        $orig = URI->new($orig);
        $orig->query_form(\%qparams);
    }

    return $orig . "";
}

# slurp an entire resultset of views
sub view_slurp {
    my ($self,$viewpath,%options) = @_;
    my $handle = $self->_new_viewhandle(\%Couchbase::View::Handle::Slurpee::);
    $viewpath = _process_viewpath_common($viewpath,%options);
    return $handle->slurp("GET", $viewpath, "");
}

sub view_iterator {
    my ($self,$viewpath,%options) = @_;
    my $handle;

    $viewpath = _process_viewpath_common($viewpath, %options);
    $handle = $self->_new_viewhandle(\%Couchbase::View::Handle::ViewIterator::);
    $handle->_perl_initialize();
    $handle->prepare("GET", $viewpath, "");
    return $handle;
}

1;

__END__

=head1 NAME


Couchbase::Bucket - Couchbase Cluster data access


=head1 SYNOPSIS


    # Imports
    use Couchbase::Bucket;
    use Couchbase::Document;

    # Create a new connection
    my $cb = Couchbase::Bucket->new("couchbases://anynode/bucket", { password => "secret" });

    # Create and store a document
    my $doc = Couchbase::Document->new("idstring", { json => ["encodable", "string"] });
    $cb->insert($doc);
    if (!$doc->is_ok) {
        warn("Couldn't store document: " . $doc->errstr);
    }

    # Retrieve a document:
    $doc = Couchbase::Document->new("user:mnunberg");
    $cb->get($doc);
    printf("Full name is %s\n", $doc->value->{name});

    # Query a view:
    my $res = Couchbase::Document->view_slurp(['design_name', 'view_name'], limit => 10);
    # $res is actually a subclass of Couchbase::Document
    if (! $res->is_ok) {
        warn("There was an error in querying the view: ".$res->errstr);
    }
    foreach my $row (@{$res->rows}) {
        printf("Key: %s. Document ID: %s. Value: %s\n", $row->key, $row->id, $row->value);
    }

    # Get multiple items at once
    my $batch = $cb->batch;
    map { $batch->get(Couchbase::Document->new("user:$_") } (qw(foo bar baz));

    while (($doc = $batch->wait_one)) {
        if ($doc->is_ok) {
            printf("Real name for userid '%s': %s\n", $doc->id, $doc->value->{name});
        } else {
            warn("Couldn't get document '%s': %s\n", $doc->id, $doc->errstr);
        }
    }


=head2 DESCRIPTION

Couchbase::Bucket is the main module for L<Couchbase> and represents a data
connection to the cluster.

The usage model revolves around an L<Couchbase::Document> which is updated
for each operation. Normally you will create a L<Couchbase::Document> and
populate it with the relevant fields for the operation, and then perform
the operation itself. When the operation has been completed the relevant
fields become updated to reflect the latest results.


=head2 CONNECTING


=head3 Connection String

To connect to the cluster, specify a URI-like I<connection string>. The connection
string is in the format of C<SCHEME://HOST1,HOST2,HOST3/BUCKET?OPTION=VALUE&OPTION=VALUE>

=over

=item scheme

This will normally be C<couchbase://>. For SSL connections, use C<couchbases://>
(note the extra I<s> at the end). See L</"Using SSL"> for more details


=item host

This can be a single host or a list of hosts. Specifying multiple hosts is not
required but may increase availability if the first node is down. Multiple hosts
should be separated by a comma.

If your administrator has configured the cluster to use non-default ports then you
may specify those ports using the form C<host:port>, where C<port> is the I<memcached>
port that the given node is listening on. In the case of SSL this should be the
SSL-enabled I<memcached> port.


=item bucket


This is the data bucket you wish to connect to. If left unspecified, it will revert
to the C<default> bucket.


=item options

There are several options which can modify connection and general settings for the
newly created bucket object. Some of these may be modifiable via L<Couchbase::Settings>
(returned via the C<settings()> method) as well. This list only mentions those
settings which are specific to the initial connection


=over

=item C<config_total_timeout>

Specify the maximum amount of time (in seconds) to wait until the client has
been connected.


=item C<config_node_timeout>

Specify the maximum amount of time (in seconds) to wait for a given node to
respond to the initial connection request. This number may also not be higher
than the value for C<config_total_timeout>.


=item C<certpath>

If using SSL, this option must be specified and should contain the local path
to the copy of the cluster's SSL certificate. The path should also be URI-encoded.


=back

=back


=head3 Using SSL


To connect to an SSL-enabled cluster, specify the C<couchbases://> for the scheme.
Additionally, ensure that the C<certpath> option contains the correct path, for example:


    my $cb = Couchbase::Bucket->new("couchbases://securehost/securebkt?certpath=/var/cbcert.pem");


=head3 Specifying Bucket Credentials

Often, the bucket will be password protected. You can specify the password using the
C<password> option in the C<$options> hashref in the constructor.


=head3 new($connstr, $options)


Create a new connection to a bucket. C<$connstr> is a L<"Connection String"> and
C<$options> is a hashref of options. The only recognized option key is C<password>
which is the bucket password, if applicable.

This method will attempt to connect to the cluster, and die if a connection could
not be made.


=head2 DATA ACCESS


Data access methods operate on an L<Couchbase::Document> object. When the operation
has completed, its status is stored in the document's C<errnum> field (you can also
use the C<is_ok> method to check if no errors occurred).


=head3 get($doc)

=head3 get_and_touch($doc)


Retrieve a document from the cluster. C<$doc> is an L<Couchbase::Document>. If the
operation is successful, the value of the item will be accessible via its C<value>
field.


    my $doc = Couchbase::Document->new("id_to_retrieve");
    $cb->get($doc);
    if ($doc->is_ok) {
        printf("Got value: %s\n", $doc->value);
    }


The C<get_and_touch> variant will also update (or clear) the expiration time of
the item. See L<"Document Expiration"> for more details.


=head3 insert($doc)

=head3 replace($doc, $options)

=head3 upsert($doc, $options)


These three methods will set the value of the document on the server. C<insert>
will only succeed if the item does B<not> exist, C<replace> will only succeed if the
item B<already> exists, and C<upsert> will unconditionally write the new value
regardless of it existing or not.


=head4 Storage Format

By default, the document is serialized and stored as JSON. This allows proper
integration with other optional functionality of the cluster (such as views and
N1QL queries). You may also store items in other formats which may then be
transparently serialized and deserialized as needed.

To specify the storage format for a document, specify the `format` setting
in the L<Couchbase::Document> object, like so:

    use Couchbase::Document;
    my $doc = Couchbase::Document->new('foo', \1234, { format => COUCHBASE_FMT_STORABLE);


This version of the client uses so-called "Common Flags", allowing seamless integration
with Couchbase clients written in other languages.


=head4 CAS Operations

To avoid race conditions when two applications attempt to write to the same document
Couchbase utilizes something called a I<CAS> value which represents the last known
state of the document. This I<CAS> value is modified each time a change is made to the
document, and is returned back to the client for each operation. If the C<$doc> item is
a document previously used for a successful C<get> or other operation, it will contain
the I<CAS>, and the client will send it back to the server. If the current I<CAS> of the
document on the server does not match the value embedded into the document the operation
will fail with the code C<COUCHBASE_KEY_EEXISTS>.

To always modify the value (ignoring whether the value may have been previously
modified by another application), set the C<ignore_cas> option to a true value in
the C<$options> hashref.


=head4 Durability Requirements

Mutation operations in couchbase are considered successful once they are stored
in the master node's cache for a given key. Sometimes extra redundancy and
reliability is required, where an application should only proceed once the data
has been replicated to a certain number of nodes and possibly persisted to their
disks. Use the C<persist_to> and C<replicate_to> options to specify the specific
durability requirements:

=over

=item C<persist_to>

Wait until the item has been persisted (written to non-volatile storage) of this
many nodes. A value of I<1> means the master node, where a value of 2 or higher
means the master node I<and> C<n-1> replica nodes.


=item C<replicate_to>

Wait until the item has been replicated to the RAM of this many replica nodes.
Your bucket must have at least this many replicas configured B<and> online for
this option to function.

=back

You may specify a I<negative> value for either C<persist_to> or C<replicate_to>
to indicate that a "best-effort" behavior is desired, meaning that replication
and persistence should take effect on as many nodes as are currently online,
which may be less than the number of replicas the bucket was configured with.

You may request replication without persistence by simply setting C<replicate_to=0>.


=head4 Document Expiration

In many use cases it may be desirable to have the document automatically
deleted after a certain period of time has elapsed (think about session management).
You can specify when the document should be deleted, either as an offset from now
in seconds (up to 30 days), or as Unix timestamp.

The expiration is considered a property of the document and is thus configurable
via the L<Couchbase::Document>'s C<expiry> method.


=head3 remove($doc, $options)

Remove an item from the cluster. The operation will fail if the item does not exist,
or if the item's L<CAS|"CAS Operations"> has been modified.


=head3 touch($doc, $options)

Update the item's expiration time. This is more efficient than L<get_and_touch> as it
does not return the item's value across the network.


=head2 Client Settings


=head3 settings()

Returns a hashref of settings (see L<Couchbase::Settings>). Because this is a hashref,
its values may be C<local>ized.


Set a high timeout for a specified operation:

    {
        local $cb->settings->{operation_timeout} = 20; # 20 seconds
        $cb->get($doc);
    }
