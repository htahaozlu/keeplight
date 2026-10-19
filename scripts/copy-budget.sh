#!/usr/bin/env bash
# Counts the user-visible words in the string literals of Sources/KeeplightUI, per surface, and
# fails above the budget (docs/design/v4-keeplight.md: product copy <= 560 words).
#
#   scripts/copy-budget.sh [BUDGET]      (default 560)
#   COPY_BUDGET_LIST=1 scripts/copy-budget.sh    also prints every counted literal
#
# A word is a whitespace-separated token with a letter in it and no format specifier (`%d`).
# Interpolations (\(...)) count as nothing, but a literal inside one (`plural(n, "display")`)
# counts, and a literal used twice on one surface counts once.
#
# Not counted, because no one sees them on screen:
#   - comments, `#if DEBUG` code (its `#else` branch is release code and is counted), debug and
#     capture files, "Debug mode" notes;
#   - log calls (`Logger`, `log.`/`modelLog.`…), assertions, defaults keys;
#   - accessibility labels, hints, values and announcements (spoken, not shown), and any line
#     marked `// copy-budget: spoken` (a helper whose result only VoiceOver reads);
#   - journal `reason:` and transaction `summary:` fields, `refused(…)` messages (the panel shows a
#     fixed sentence instead), string comparisons (`== "…"`, `hasPrefix("…")`…);
#   - render-tool target names (`.hitTarget`), SF Symbol names, identifier-like literals (keys,
#     dictionary and animation keys, ids, file names, URLs, ENV_NAMES), journal `before:`/`after:`
#     values, single letters.
# Outside this count: text that lives in DisplayCore (diagnosis step names and details, private
# interface descriptions) and is shown in Settings › Displays › Details and About › Private APIs.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
budget="${1:-560}"

report="$(find "$root/Sources/KeeplightUI" -name '*.swift' \
    ! -name 'AppModel+Debug.swift' ! -name 'DebugCapture.swift' -print0 | sort -z |
    xargs -0 perl -e '
use strict; use warnings;

# The string literals on one line of Swift: interpolations removed, literals nested in them kept.
sub literals {
    my ($line) = @_;
    my @found;
    my @chars = split //, $line;
    my ($i, $n) = (0, scalar @chars);
    while ($i < $n) {
        if ($chars[$i] eq q{"}) {
            my ($text, $depth) = ("", 0);
            $i++;
            while ($i < $n) {
                my $c = $chars[$i];
                if ($depth == 0) {
                    last if $c eq q{"};
                    if ($c eq "\\") {
                        if ($i + 1 < $n && $chars[$i + 1] eq "(") { $depth = 1; $i += 2; $text .= " "; next }
                        $text .= " "; $i += 2; next;
                    }
                    $text .= $c;
                } else {
                    if ($c eq q{"}) {
                        my ($j, $inner) = ($i + 1, "");
                        while ($j < $n && $chars[$j] ne q{"}) { $inner .= $chars[$j]; $j++ }
                        push @found, $inner;
                        $i = $j + 1;
                        next;
                    }
                    $depth++ if $c eq "(";
                    $depth-- if $c eq ")";
                }
                $i++;
            }
            push @found, $text;
        }
        $i++;
    }
    return @found;
}

my (%seen, %words);
for my $file (@ARGV) {
    my $surface = $file =~ m{/(Panel|Settings|Overlays|Shell|Model|System|Design|Onboarding)/} ? $1 : "App";
    open my $fh, "<", $file or die "$file: $!";
    # One entry per open #if: 1 = skipping (DEBUG branch), 0 = counting.
    my @conditions;
    while (my $line = <$fh>) {
        if ($line =~ /^\s*#if\b/) { push @conditions, ($line =~ /^\s*#if DEBUG\b/ ? 1 : 0); next }
        if ($line =~ /^\s*#else\b/ && @conditions) { $conditions[-1] = $conditions[-1] ? 0 : (grep { $_ } @conditions[0 .. $#conditions - 1]) ? 1 : 0; next }
        if ($line =~ /^\s*#endif\b/ && @conditions) { pop @conditions; next }
        next if grep { $_ } @conditions;
        next if $line =~ /^\s*(import\b|\/\/)/;
        next if $line =~ m{//\s*copy-budget:\s*spoken\b};
        $line =~ s{(?<![:"])//.*$}{};
        # Comparisons and string surgery: the literal is matched against, never shown.
        $line =~ s{\b(?:hasPrefix|hasSuffix|localizedCaseInsensitiveContains|contains)\("[^"]*"\)}{}g;
        $line =~ s{replacingOccurrences\(of: "[^"]*", with: "[^"]*"\)}{}g;
        $line =~ s{(?:==|!=)\s*"[^"]*"}{}g;
        # Keys: dictionary keys (`["path": …]`), animation keys, journal before/after values.
        $line =~ s{"[A-Za-z.]+":\s}{}g;
        $line =~ s{\b(?:key|before|after):\s*"[^"\\]*"}{}g;
        next if $line =~ /\bkeyPath\b|static let (\w+) = "\1"/;
        next if $line =~ /[Aa]ccessibility(Label|Hint|Value)\(|\bannounce\(|\bLogger\b|\bos_log\b|\bprint\(|fatalError\(|precondition|assert|\.log\(|\b\w*[Ll]og\.(info|error|debug|notice|warning|fault)\(|\breason:|\bsummary:|\brefused\(|\.hitTarget\(|systemName:|systemSymbolName:|symbol:|NSImage\(named|forKey|UserDefaults|environment\[|ProcessInfo|appendingPathComponent/;
        for my $text (literals($line)) {
            next unless $text =~ /[A-Za-z]/;
            next if $text =~ /^\s*Debug mode/;
            next if $text =~ /^\s*[A-Za-z]\s*$/;                                   # single letters
            next if $text !~ /\s/ && $text =~ /^[a-z][A-Za-z0-9_.:\/%\@-]*$/
                && $text =~ /[._:\/%\@0-9-]|[a-z][A-Z]/;                            # keys, ids, symbols
            next if $text !~ /\s/ && $text =~ /^[A-Z][A-Z0-9]*_[A-Z0-9_]+$/;       # ENV_NAMES
            next if $text =~ /^[a-z][a-z0-9.+-]*:(\S|\s*$)/ || $text =~ /^%/;      # URLs, key prefixes, formats
            next if $text =~ /^#?[0-9A-Fa-f]{6}$/;
            next if $text !~ /\s/ && $text =~ /^(AX|CF|DP|NS)[A-Za-z]+$/;           # Info.plist and AppKit keys
            my $count = grep { /[A-Za-z]/ && !/%/ } split /\s+/, $text;
            next unless $count;
            my $key = $text; $key =~ s/^\s+|\s+$//g;
            next if $seen{$surface}{$key}++;
            $words{$surface} += $count;
            print "LITERAL $surface\t$count\t$key\n" if $ENV{COPY_BUDGET_LIST};
        }
    }
}
my $total = 0;
for my $surface (sort keys %words) {
    printf "%-10s %4d words\n", $surface, $words{$surface};
    $total += $words{$surface};
}
printf "%-10s %4d words\n", "total", $total;
print "TOTAL=$total\n";
')"

total="$(sed -n 's/^TOTAL=//p' <<< "$report")"
grep -v '^TOTAL=' <<< "$report"
if (( total > budget )); then
    echo "copy-budget: FAIL $total words, budget $budget" >&2
    exit 1
fi
echo "copy-budget: ok, $total of $budget words"
