#!/usr/bin/env perl
#
# Scan a directory for files with extensions, read the first 32 bytes of each,
# group by extension, find common bytes across all files in each group,
# and output a regex pattern for magic byte detection.
#
# Usage: perl find_magic.pl <directory>
#
# -samy kamkar

use strict;
use warnings;

die "Usage: $0 [-d] [-a] [-n bytes] <directory>\n" unless @ARGV >= 1;

my $use_dirname = 0;
my $all_files = 0;
my $header_bytes;
while (@ARGV && $ARGV[0] =~ /^-/) {
    if ($ARGV[0] eq '-d') {
        $use_dirname = 1;
        shift @ARGV;
    } elsif ($ARGV[0] eq '-a') {
        $all_files = 1;
        shift @ARGV;
    } elsif ($ARGV[0] eq '-n') {
        shift @ARGV;
        $header_bytes = shift @ARGV;
    } else {
        die "Unknown option: $ARGV[0]\n";
    }
}
die "Usage: $0 [-d] [-a] [-n bytes] <directory>\n" unless @ARGV >= 1;
my $dir = $ARGV[0];

# Recursively find all files with an extension
my @files;
sub scan_dir {
    my ($d) = @_;
    opendir(my $dh, $d) or do { warn "Cannot open $d: $!\n"; return };
    while (my $entry = readdir($dh)) {
        next if $entry =~ /^\.\.?$/;
        my $path = "$d/$entry";
        if (-d $path) {
            scan_dir($path);
        } elsif (-f $path) {
            if ($all_files) {
                push @files, { path => $path, ext => '_all' };
            } elsif ($entry =~ /\.([^.]+)$/) {
                push @files, { path => $path, ext => lc($1) };
            }
        }
    }
    closedir($dh);
}

scan_dir($dir);

# Group files by extension
my %by_ext;
for my $f (@files) {
    push @{ $by_ext{$f->{ext}} }, $f->{path};
}

my $HEADER_BYTES = $header_bytes // 64;
my @results;

for my $ext (sort keys %by_ext) {
    my @paths = @{ $by_ext{$ext} };
    next if @paths < 2;  # need at least 2 files to compare

    # Read first 32 bytes of each file as hex
    my @hex_strings;
    for my $path (@paths) {
        open(my $fh, '<:raw', $path) or do { warn "Cannot read $path: $!\n"; next };
        my $buf;
        my $n = read($fh, $buf, $HEADER_BYTES);
        close $fh;
        next unless defined $n && $n > 0;

        # Pad to full length if file is shorter
        $buf .= "\0" x ($HEADER_BYTES - $n) if $n < $HEADER_BYTES;
        push @hex_strings, { hex => unpack("H*", $buf), path => $path, len => $n };
    }

    next if @hex_strings < 2;

    # Compare each hex nibble position across all files
    my $hex_len = $HEADER_BYTES * 2;
    my @pattern;
    my $common_count = 0;

    for my $i (0 .. $hex_len - 1) {
        my %nibbles;
        for my $h (@hex_strings) {
            $nibbles{ substr($h->{hex}, $i, 1) }++;
        }
        if (keys %nibbles == 1) {
            # All files have the same nibble here
            push @pattern, (keys %nibbles)[0];
            $common_count++;
        } else {
            # Differs across files
            push @pattern, '.';
        }
    }

    my $pattern_str = join('', @pattern);

    # Skip if too few common bytes (less than 25% of nibbles matching)
    my $match_pct = int($common_count / $hex_len * 100);
    next if $match_pct < 25;

    # Trim trailing wildcards
    $pattern_str =~ s/\.+$//;

    # Determine description: use common parent dir name if -d, else extension
    my $desc = $ext eq '_all' ? 'unknown' : $ext;
    my $out_ext = $ext eq '_all' ? 'bin' : $ext;
    if ($use_dirname) {
        my %dirs;
        for my $h (@hex_strings) {
            (my $d = $h->{path}) =~ s{/[^/]+$}{};  # strip filename
            $d =~ s{^.*/}{};                         # keep lowest dir name
            $dirs{$d}++;
        }
        if (keys %dirs == 1) {
            $desc = (keys %dirs)[0];
        }
    }

    # Store result for output and collision check
    push @results, {
        pattern => $pattern_str,
        ext     => $out_ext,
        desc    => $desc,
        count   => scalar @hex_strings,
        pct     => $match_pct,
        samples => [map { $_->{hex} } @hex_strings[0 .. ($#hex_strings > 2 ? 2 : $#hex_strings)]],
    };
}

# Output all results
for my $r (@results) {
    printf "    # %d files, %d%% common nibbles\n", $r->{count}, $r->{pct};
    printf "    [qr/^%s/, '.%s', '%s'],\n", $r->{pattern}, $r->{ext}, $r->{desc};
    for my $s (@{ $r->{samples} }) {
        printf "    #   %s\n", $s;
    }
    print "\n";
}

# Check for collisions: test each pattern's samples against all other patterns
my $collisions = 0;
for my $i (0 .. $#results) {
    for my $j ($i + 1 .. $#results) {
        my $ri = $results[$i];
        my $rj = $results[$j];
        my $re_i = qr/^$ri->{pattern}/;
        my $re_j = qr/^$rj->{pattern}/;

        # Check if any sample from i matches pattern j
        for my $s (@{ $ri->{samples} }) {
            if ($s =~ $re_j) {
                warn sprintf("WARNING: .%s sample matches .%s pattern — possible collision\n",
                    $ri->{ext}, $rj->{ext});
                warn "  sample: $s\n";
                $collisions++;
                last;
            }
        }
        # Check if any sample from j matches pattern i
        for my $s (@{ $rj->{samples} }) {
            if ($s =~ $re_i) {
                warn sprintf("WARNING: .%s sample matches .%s pattern — possible collision\n",
                    $rj->{ext}, $ri->{ext});
                warn "  sample: $s\n";
                $collisions++;
                last;
            }
        }
    }
}

if ($collisions) {
    warn "\n$collisions collision(s) detected! Reorder \@MAGIC so more specific patterns come first.\n";
} else {
    print "# No collisions detected between patterns.\n";
}
