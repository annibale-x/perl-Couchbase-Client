package Couchbase::Core;
use strict;
use warnings;
our $VERSION;
BEGIN {
    require XSLoader;
    $VERSION = '2.0.2';
    XSLoader::load('Couchbase', $VERSION);
}

1;
