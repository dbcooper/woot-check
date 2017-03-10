#!/usr/bin/env perl

# Check Woot.com site for computer deals (Title) that one or more keywords.  Output HTML/send email containing links and details for each [matching] offer

use strict;
use warnings;
use utf8;
use feature ':5.10';

use Encode qw(encode decode from_to);
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);
use Data::Dumper;
use Getopt::Std;
use Config::General;
use File::Temp;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use Try::Tiny;

my %opts;
getopts('c:do:', \%opts);   # -c <config_filename>, -d[ebug], -o <output_filename>
my $config_file = $opts{c} || 'woot.conf';
my $conf = Config::General->new($config_file);
my %CONFIG = $conf->getall;
my $debug;
$debug = 1 if ($CONFIG{debug} or $opts{d});

# Woot! API configuration variables
my $ek_str = $CONFIG{Keywords}->{event};
die "?No event keywords defined in $config_file, quitting\n" unless ($ek_str);
my $event_keywords = str2keywords($ek_str);
my $ok_str = $CONFIG{Keywords}->{offer} || $CONFIG{Keywords}->{event};
my $offer_keywords = str2keywords($ok_str);
my $api_key = $CONFIG{Secrets}->{apikey};
die "?No API key defined in $config_file, quitting\n" unless ($api_key);

my $ua = Mojo::UserAgent->new;

# Simple first search

# Give me enough to find the Id of entry e.g. where Title = "Business Class Laptops".  I know they're [specifically] WootPlus events
# There's too much data in raw response so we use select keyword
#
# See http://api.woot.com/2 for more information
my $start_url = "http://api.woot.com/2/events.json?key=$api_key&site=computers.woot.com&eventType=WootPlus&select=Title,SubTitle,Site,StartDate,EndDate";
my $events = get_json($start_url);
my %keyword_matches;                    # track keyword hits for email summary
my @matches;
for my $e (@$events) {
    if (my $lref = keywords_in_text($event_keywords, $e->{Title})) {
        my $match = join('', '[ ', join(', ', @${lref}), ' ]');
        $keyword_matches{$match}++;
        warn "?$match matched \"" . $e->{Title} . "\"\n" if ($debug);
        push @matches, $e;
    }
    elsif ($debug) {
        warn "?no matches for \"" . $e->{Title} . "\"\n";
    }
}
warn "?matched " . scalar(@matches) . " events\n" if ($debug);

# In the last query we determined the specific event Ids we're interested in (e.g., "1c5144c0-9f35-4de1-acf8-1886869a7a26")
# There are multiple offers inside of it
# We're not interested in all the offers offers, so we do some filtering here by searching the titles of ongoing offers (SoldOut == false) for keywords or phrases we're interested in.
# E.g., latitude rugged, latitude 5414, latitude e7[42]70.  Don't care about positioning of words relative to each other as long as /all/ are present in the title

# Gather the Offer JSON entry where our filter responds positively to the Title
my @offers;                             # Offers we're interested in
for my $e (@matches) {
    my $id = $e->{Id};                  # event Id
    my $url = "https://api.woot.com/2/events/$id.json?key=$api_key&select=Title,Site,StartDate,EndDate,Offers.Title,Offers.Subtitle,Offers.SoldOut,Offers.PercentageRemaining";
    my $json_obj = get_json($url);
    for my $o ( @{$json_obj->{Offers}} ) {  # for each offer in an event
        next if $o->{SoldOut};
        if (my $lref = keywords_in_text($offer_keywords, $o->{Title})) {
            my $match = join('', '[ ', join(', ', @${lref}), ' ]');
            $keyword_matches{$match}++;
            warn "?$match matched \"" . $o->{Title} . "\"\n" if ($debug);
            push @offers, $o;
        }
        elsif ($debug) {
            warn "?no matches for \"" . $o->{Title} . "\"\n";
        }
    }
}

my $summary = "Aggregated " . scalar(@offers) . " offers across " . scalar(@matches) . " events, matching " . join(', ', sort keys %keyword_matches) . " keywords\n";
warn "?$summary" if ($debug);
unless (@offers) {
    warn "?No offers w/ keywords found in " . scalar(@matches) ." events, bailing out\n";
    exit;
}

# For each offer Id, generate a useful [HTML] blurb about it
my @blurbs;                             # html blurbs for each item
for my $o (@offers) {
    my $id = $o->{Id};                  # offer Id
    my $url = "http://api.woot.com/2/offers/$id.json?key=$api_key&select=Features,Items,Url,SoldOut,Specs,Subtitle,Title,Photos";
    my $json_obj = get_json($url);
    next if ($json_obj->{SoldOut});
    my $html = offer2html($json_obj);
    push @blurbs, encode('utf8', "$html\n");
}

# Generate HTML content/page, stash in file
my $body = generate_html($summary, \@blurbs);
my ($fh, $filename);
if ($opts{o}) {
    $filename = $opts{o};
    open $fh, '>', $filename || die "?unable to open $filename for writing: $!";
}
else {
    $fh = File::Temp->new();
    $filename = $fh->filename;
}
print $fh $body;
close $fh;
warn "?wrote deal summary information (HTML) to $filename\n" if ($debug);

# TODO Stash offer information in database?, check to see if there are any new offers or offer changes we haven't seen before sending email

# Try to send email
if ($CONFIG{Email}->{to}) {
    my $to = [ split /[,;]/, $CONFIG{Email}->{to} ];
    my $email = Email::Simple->create(
        header => [
            Subject        => 'Woot.com product matches',
            'Content-Type' => 'text/html; charset=UTF-8'
        ],
        body => $body
    );
    my $transport = Email::Sender::Transport::SMTP->new({
            host => $CONFIG{Email}->{smtp},
    });
    try {
        sendmail($email,
            {   to        => $to,
                from      => $CONFIG{Email}->{from},
                transport => $transport,
            }
        );
        my $to_str = join(',', @{$to});
        warn "?send email to $to_str completed without error\n" if ($debug);
    }
    catch {
        warn "?sending email failed: $_\n";
    };
}

# exit


# Returns Perl object on successful retrieval and parsing of JSON
sub get_json
{
    my ($url) = shift;

    warn "?retrieving $url\n" if ($debug);

    my $res = $ua->get($url)->result;
    if ( $res->is_success )  {
        return decode_json($res->body);
    }
    elsif ( $res->is_error )  {
        warn sprintf qq(?error trying to retrieve "$url": %d %s\n), $res->code, $res->message;
    }
    elsif ( $res->code == 301 ) {
        warn sprintf "?Permanently moved to %s\n", $res->headers->location;
    }
    else {
        warn "?idk what happened\n";
    }
    return;
}

# See if one of the sets of words in keyword array are /all/ contained with the text phrase
# Stops on first match and returns lref containing matching keywords on success
sub keywords_in_text
{
    my ($keywords_lref, $text) = @_;

KEYWORD_SET:
    for my $lref (@{$keywords_lref}) {
        for my $keyword (@{$lref}) {
            next KEYWORD_SET unless ($text =~ m/$keyword/i);
        }
        return $lref;                   # quit after first match
    }
    # If we're here, no matches found
}

# Convert string of keywords into list reference format used by keywords_in_text()
sub str2keywords
{
    my ($str) = @_;

    # I guess I'm guilty of [trying to] code golf :\
    return [ map { my @k = split /\s+/, $_; [ grep(!/^\s*$/, @k) ] } split /;/, $str ];
}

# Convert a single Offer perl [anonymous] hash (from JSON) into an HTML chunk w/ the following information
#
#  * Url<Title>,
#  * Photos[0]: Url, Width, Height
#  * Items » SalePrice,
#  * Features
#
sub offer2html
{
    my ($obj) = @_;

    # Shortcuts for in-string dereferencing
    my %item = %{$obj->{Items}->[0]};
    undef $obj->{Items};
    my %photo = %{$obj->{Photos}->[0]};
    undef $obj->{Photos};
    my %hash = %{$obj};                 # Remaining keys

    # NOTE This string will [likely] be in UTF-8 and need to be printed via encode()
my $html=<<EOL
<a href="$hash{Url}"><img src="$photo{Url}" width=$photo{Width} height=$photo{Height} alt="$hash{Title}"></a> <br />
<a href="$hash{Url}">$hash{Title}</a> - $item{SalePrice} <br />
<div class="features">
$hash{Features}
</div>

EOL
    ;
    return $html;
}

# Build HTML email/report about new deals
sub generate_html
{
    my ($lead, $lref) = @_;

    my $now = localtime();
    my $html =<<HEAD_EOL
<!doctype html>
<html lang="en">
<head>
<title>Select Woot! Deals as of $now</title>
<!-- Generated by $0 on $now -->
<meta charset=utf-8>
<style type="text/css">
.features { font-size: 0.9em; }
</style>
</head>
<body>

<p> $summary
</p>

HEAD_EOL
    ;
    $html .= join("\n<hr />\n", @blurbs);
    $html .= "</body></html>\n";
    return $html;
}
