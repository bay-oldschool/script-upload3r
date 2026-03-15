#!/usr/bin/perl
# Extract a JSON field value with full unicode decoding (including surrogate pairs)
# Usage: json_field.pl [-n] <field> <file>
#   -n  Extract numeric value instead of string
use strict;
use warnings;
use Encode;

my $numeric = 0;
if (@ARGV && $ARGV[0] eq '-n') {
    $numeric = 1;
    shift @ARGV;
}

my $field = $ARGV[0] or die "Usage: json_field.pl [-n] <field> <file>\n";
my $file  = $ARGV[1] or die "Usage: json_field.pl [-n] <field> <file>\n";

open(my $fh, '<:raw', $file) or die "Cannot open $file: $!\n";
local $/;
my $json = <$fh>;
close($fh);

if ($numeric) {
    # Match numeric value
    if ($json =~ /"\Q$field\E"\s*:\s*(\d+)/) {
        print $1;
    }
} else {
    # Match string value (handles escaped chars inside the string)
    if ($json =~ /"\Q$field\E"\s*:\s*"((?:[^"\\]|\\.)*)"/s) {
        my $d = $1;
        # Decode unicode escapes (including surrogate pairs for emoji)
        $d =~ s/\\u([Dd][89AaBb][0-9a-fA-F]{2})\\u([Dd][CcDdEeFf][0-9a-fA-F]{2})/
            chr(0x10000 + ((hex($1) - 0xD800) << 10) + (hex($2) - 0xDC00))/ge;
        $d =~ s/\\u([0-9a-fA-F]{4})/chr(hex($1))/ge;
        # Decode other JSON escapes
        $d =~ s/\\n/\n/g;
        $d =~ s/\\r//g;
        $d =~ s/\\t/\t/g;
        $d =~ s/\\"/"/g;
        $d =~ s/\\\\/\\/g;
        $d =~ s/\\\//\//g;
        print encode('UTF-8', $d);
    }
}
