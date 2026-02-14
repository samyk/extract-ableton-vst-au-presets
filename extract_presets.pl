#!/usr/bin/env perl
#
# extract VST/AU presets from Ableton Live project files so the presets can be reloaded
# even if you don't have the original VST/AU plugin installed
#
# -samy kamkar

use strict;
use warnings;
use XML::LibXML;
use File::Path qw(make_path);
use File::Spec;
use File::Basename;
use MIME::Base64;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

die "Usage: $0 <xml_file> [output_dir]\n" unless @ARGV >= 1;

my $xml_file   = $ARGV[0];
my ($basename)  = fileparse($xml_file, qr/\.[^.]*/);
my $output_dir = $ARGV[1] // "${basename}.presets";

make_path($output_dir) unless -d $output_dir;

# Read raw bytes, try XML first, fall back to gzip decompression
my $raw;
{
    open my $fh, '<:raw', $xml_file or die "Cannot read $xml_file: $!\n";
    local $/;
    $raw = <$fh>;
    close $fh;
}

my $xml_string;
my $parser = XML::LibXML->new;

eval { $parser->parse_string($raw); $xml_string = $raw; };
if ($@) {
    # Not valid XML, try gzip decompression
    print "Input is not XML, attempting gzip decompression...\n";
    gunzip(\$raw => \$xml_string)
        or die "Failed to decompress: $GunzipError\n";
    print "Decompressed successfully.\n";
}

my $doc = $parser->parse_string($xml_string);
my @buffers = $doc->findnodes('//Buffer');

printf "Found %d Buffer node(s)\n", scalar @buffers;

my $counter = 0;
my %written_files;
for my $buf (@buffers) {
    my @name_parts;

    # Walk ancestors from root down to the Buffer's parent
    my @ancestors;
    my $node = $buf->parentNode;
    while ($node && $node->nodeType == XML_ELEMENT_NODE) {
        unshift @ancestors, $node;
        $node = $node->parentNode;
    }

    for my $anc (@ancestors) {
        my $tag = $anc->nodeName;

        # Count same-named siblings to determine index (1-based)
        my $parent = $anc->parentNode;
        if ($parent && $parent->nodeType == XML_ELEMENT_NODE) {
            my @siblings = $parent->getChildrenByTagName($tag);
            if (@siblings > 1) {
                my $idx = 1;
                for my $sib (@siblings) {
                    last if $sib->isSameNode($anc);
                    $idx++;
                }
                push @name_parts, "${tag}${idx}";
            }
        }

        # Collect all name variants for this ancestor
        my %names;
        for my $name_el ($anc->getChildrenByTagName('Name')) {
            my @eff = $name_el->getChildrenByTagName('EffectiveName');
            if (@eff) {
                my $val = $eff[0]->getAttribute('Value');
                $names{EffectiveName} = $val if defined $val && $val ne '';
            }
            my $val = $name_el->getAttribute('Value');
            $names{Name} = $val if defined $val && $val ne '';

            for my $un ($name_el->getChildrenByTagName('UserName')) {
                my $uval = $un->getAttribute('Value');
                $names{UserName} = $uval if defined $uval && $uval ne '';
            }
        }
        for my $plug_el ($anc->getChildrenByTagName('PlugName')) {
            my $val = $plug_el->getAttribute('Value');
            $names{PlugName} = $val if defined $val && $val ne '';
        }

        # Debug: print all name variants if multiple exist
        if (keys %names > 1) {
            print STDERR "  [$tag] names: " . join(', ', map { "$_=\"$names{$_}\"" } sort keys %names) . "\n";
        }

        # Priority: EffectiveName > Name > PlugName
        my $chosen = $names{EffectiveName} // $names{Name} // $names{PlugName};
        push @name_parts, $chosen if defined $chosen;
    }

    # Fallback filename if no EffectiveName found
    if (!@name_parts) {
        push @name_parts, "buffer_" . $counter++;
    }

    my $filename = join('.', @name_parts);
    #print "Filename: $filename\n";
    # Sanitize for filesystem
    $filename =~ s/[\/\\:*?"<>|]/_/g;
    my $content = $buf->textContent;
    $content =~ s/\s+//g;
    $content =~ s/(..)/pack "H2", $1/eg;

    my $path = File::Spec->catfile($output_dir, $filename);

    if ($content =~ /^\s*</) {
        # It's XML — write .xml file
        warn "  WARNING: overwriting previously written $path.xml\n" if $written_files{$path . '.xml'}++;
        open(my $fh, '>', $path . '.xml') or die "Cannot write $path.xml: $!\n";
        print $fh $content;
        close $fh;
        print "$path.xml\n";

        # Extract each <key>...<data> pair, base64 decode and write as .keyname.bin
        eval {
            my $inner_doc = XML::LibXML->new->parse_string($content);
            my @data_nodes = $inner_doc->findnodes('//dict/data');
            for my $data_node (@data_nodes) {
                # Find the preceding <key> sibling for this <data>
                my $key_name = 'unknown';
                my $prev = $data_node->previousNonBlankSibling;
                while ($prev) {
                    if ($prev->nodeType == XML_ELEMENT_NODE && $prev->nodeName eq 'key') {
                        $key_name = $prev->textContent;
                        $key_name =~ s/\s+/_/g;
                        last;
                    }
                    $prev = $prev->previousNonBlankSibling;
                }

                my $b64 = $data_node->textContent;
                $b64 =~ s/\s+//g;

                my $bin_path = "${path}.${key_name}.bin";
                eval {
                    my $bin = decode_base64($b64);
                    warn "  WARNING: overwriting previously written $bin_path\n" if $written_files{$bin_path}++;
                    open(my $bfh, '>:raw', $bin_path) or die "Cannot write $bin_path: $!\n";
                    print $bfh $bin;
                    close $bfh;
                    print "$bin_path\n";
                };
                warn "  WARNING: base64 decode failed for $key_name in $filename: $@\n" if $@;
            }
        };
        warn "  Warning: could not parse inner XML for $filename: $@" if $@;
    } else {
        # Not XML — write raw decoded content directly as .bin
        warn "  WARNING: overwriting previously written $path.bin\n" if $written_files{$path . '.bin'}++;
        open(my $bfh, '>:raw', $path . '.bin') or die "Cannot write $path.bin: $!\n";
        print $bfh $content;
        close $bfh;
        print "$path.bin\n";
    }
    print "  XPath: " . $buf->nodePath() . "\n";
}

print "Done.\n";
