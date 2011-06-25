# This file contains various stubs. Note that a few are created already
# outside of the setting, such as Mu/Any/Cool, Attribute, Signature/Parameter,
# Code/Block/Routine/Sub/Method and Str/Int/Num. They are built in BOOTSTRAP.pm
# in Perl6::Metamodel for now, though should be a BEGIN block in CORE.setting
# in the end.
my class Junction is Mu { }
my class Whatever is Cool { }


# lookup of dynamic variables
sub DYNAMIC(\$name) { 
    my Mu $x := pir::find_dynamic_lex__Ps(nqp::unbox_s($name));
    if nqp::isnull($x) {
        my $pkgname = nqp::p6box_s(pir::replace__Ssiis(nqp::unbox_s($name), 1, 1, ''));
        $x := "PROCESS::\{$pkgname} NYI";   # XXX remove quotes when we can do PROCESS:: lookups
    }
    $x
}


