#!/usr/bin/perl
# Extract description from UNIT3D edit page Livewire data
use strict;
use warnings;
use Encode;

local $/;
my $html = <STDIN>;

if ($html =~ /contentBbcode&quot;:&quot;((?:\\&quot;|(?!&quot;)[^&]|&(?!quot;))*)&quot;/) {
    my $d = $1;
    $d =~ s/&amp;/&/g;
    $d =~ s/&quot;/"/g;
    # Decode surrogate pairs for emoji
    $d =~ s/\\u([Dd][89AaBb][0-9a-fA-F]{2})\\u([Dd][CcDdEeFf][0-9a-fA-F]{2})/
        chr(0x10000 + ((hex($1) - 0xD800) << 10) + (hex($2) - 0xDC00))/ge;
    # Decode BMP unicode escapes
    $d =~ s/\\u([0-9a-fA-F]{4})/chr(hex($1))/ge;
    # Decode JSON string escapes
    $d =~ s/\\n/\n/g;
    $d =~ s/\\r//g;
    $d =~ s/\\t/\t/g;
    $d =~ s/\\"/"/g;
    $d =~ s|\\\\|\\|g;
    $d =~ s|\\/|/|g;
    print encode('UTF-8', $d);
}
