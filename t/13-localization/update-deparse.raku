#!/usr/bin/env raku

use v6.e.PREVIEW;
use RakuAST::Deparse::L10N;

# Helper script to update the localized deparse of available
# localizations.
#
# This script assumes that deparsing is correct at time of execution.

my $io  := $*PROGRAM.sibling("sources");
my $ast := $io.add("basic").slurp.AST;

for RakuAST::Deparse::L10N::.keys.sort {
    $io.add("basic.$_").spurt($ast.DEPARSE($_));
}

# vim: expandtab shiftwidth=4
