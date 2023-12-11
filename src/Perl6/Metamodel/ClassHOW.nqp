class Perl6::Metamodel::ClassHOW
    does Perl6::Metamodel::Naming
    does Perl6::Metamodel::Documenting
    does Perl6::Metamodel::LanguageRevision
    does Perl6::Metamodel::Stashing
    does Perl6::Metamodel::AttributeContainer
    does Perl6::Metamodel::MethodContainer
    does Perl6::Metamodel::PrivateMethodContainer
    does Perl6::Metamodel::MultiMethodContainer
    does Perl6::Metamodel::MetaMethodContainer
    does Perl6::Metamodel::RoleContainer
    does Perl6::Metamodel::MultipleInheritance
    does Perl6::Metamodel::DefaultParent
    does Perl6::Metamodel::C3MRO
    does Perl6::Metamodel::MROBasedMethodDispatch
    does Perl6::Metamodel::MROBasedTypeChecking
    does Perl6::Metamodel::Trusting
    does Perl6::Metamodel::BUILDPLAN
    does Perl6::Metamodel::Mixins
    does Perl6::Metamodel::ArrayType
    does Perl6::Metamodel::BoolificationProtocol
    does Perl6::Metamodel::REPRComposeProtocol
    does Perl6::Metamodel::InvocationProtocol
    does Perl6::Metamodel::ContainerSpecProtocol
    does Perl6::Metamodel::Finalization
    does Perl6::Metamodel::Concretization
    does Perl6::Metamodel::ConcretizationCache
{
    has @!roles;
    has @!role_typecheck_list;
    has @!fallbacks;
    has $!composed;
    has $!is_pun;
    has $!pun_source; # If class is coming from a pun then this is the source role
    has $!archetypes;
    has $!archt-lock;

    my $archetypes-ng := Perl6::Metamodel::Archetypes.new( :nominal, :inheritable, :augmentable );
    my $archetypes-g  := Perl6::Metamodel::Archetypes.new( :nominal, :inheritable, :augmentable, :generic );

    method archetypes($obj = nqp::null()) {
#?if moar
        # The dispatcher itself is declared at the end of this file. We can't have it in the BOOTSTRAP because the
        # bootstrap process is using archetypes long before dispatchers from dispatchers.nqp gets registered.
        nqp::dispatch('raku-class-archetypes', self, $obj)
#?endif
#?if !moar
        if nqp::isconcrete(my $dcobj := nqp::decont($obj)) && nqp::can($dcobj, 'is-generic') {
            return $dcobj.is-generic ?? $archetypes-g !! $archetypes-ng;
        }
        $!archetypes // $archetypes-ng
#?endif
    }

    method new(*%named) {
        nqp::findmethod(NQPMu, 'BUILDALL')(nqp::create(self), %named)
    }

    method !refresh_archetypes($obj) {
        $!archetypes :=
            nqp::can($obj, 'is-generic') && $obj.is-generic
                ?? $archetypes-g
                !! $archetypes-ng
    }

    my $id_lock := NQPLock.new;
    my $anon_id := 1;
    method new_type(:$name, :$repr = 'P6opaque', :$ver, :$auth, :$api, :$is_mixin) {
        my $metaclass := self.new();
        my $new_type;
        if $is_mixin {
            $new_type := nqp::newmixintype($metaclass, $repr);
        }
        else {
            $new_type := nqp::newtype($metaclass, $repr);
        }
        my $obj := nqp::settypehll($new_type, 'Raku');
        $metaclass.set_name($obj, $name // "<anon|{
                $id_lock.protect: { $anon_id++ }
            }>");
        self.add_stash($obj);
        $metaclass.set_ver($obj, $ver) if $ver;
        $metaclass.set_auth($obj, $auth) if $auth;
        $metaclass.set_api($obj, $api) if $api;
        $metaclass.setup_mixin_cache($obj);
        nqp::bindattr($metaclass, Perl6::Metamodel::ClassHOW, '$!archt-lock', NQPLock.new);
        nqp::setboolspec($obj, 5, nqp::null());
        $obj
    }

    # Adds a new fallback for method dispatch. Expects the specified
    # condition to have been met (passes it the object and method name),
    # and if it is calls $calculator with the object and method name to
    # calculate an invokable object.
    method add_fallback($obj, $condition, $calculator) {
#?if !moar
        # Adding a fallback means any method cache is no longer authoritative.
        nqp::setmethcacheauth($obj, 0);
#?endif

        # Add it.
        my %desc;
        %desc<cond> := $condition;
        %desc<calc> := $calculator;
        @!fallbacks[+@!fallbacks] := %desc;
    }

    sub has_method($target, $name) {
        for $target.HOW.mro($target) {
            my %mt := nqp::hllize($_.HOW.method_table($_));
            if nqp::existskey(%mt, $name) {
                return 1;
            }
            %mt := nqp::hllize($_.HOW.submethod_table($_));
            if nqp::existskey(%mt, $name) {
                return 1;
            }
        }
        return 0;
    }

    method compose($the-obj, :$compiler_services) {
        my $obj := nqp::decont($the-obj);

        self.set_language_version($obj);

        # Instantiate all of the roles we have (need to do this since
        # all roles are generic on ::?CLASS) and pass them to the
        # composer.
        my @roles_to_compose := self.roles_to_compose($obj);
        my @stubs;
        my $rtca;
        if @roles_to_compose {
            my @ins_roles;
            while @roles_to_compose {
                my $r := @roles_to_compose.pop();
                @!roles[+@!roles] := $r;
                @!role_typecheck_list[+@!role_typecheck_list] := $r;
                my $ins := $r.HOW.specialize($r, $obj);
                # If class is a result of pun then transfer hidden flag from the source role
                if $!pun_source =:= $r {
                    self.set_hidden($obj) if $ins.HOW.hidden($ins);
                    self.set_language_revision($obj, $ins.HOW.language_revision($ins), :force);
                }
                @ins_roles.push($ins);
                self.add_concretization($obj, $r, $ins);
            }
            self.compute_mro($obj); # to the best of our knowledge, because the role applier wants it.
            $rtca := Perl6::Metamodel::Configuration.role_to_class_applier_type.new;
            $rtca.prepare($obj, @ins_roles);

            self.wipe_conc_cache;

            # Add them to the typecheck list, and pull in their
            # own type check lists also.
            for @ins_roles {
                @!role_typecheck_list[+@!role_typecheck_list] := $_;
                for $_.HOW.role_typecheck_list($_) {
                    @!role_typecheck_list[+@!role_typecheck_list] := $_;
                }
            }
        }

        # Compose class attributes first. We prioritize them and their accessors over anything coming from roles.
        self.compose_attributes($obj, :$compiler_services);

        if $rtca {
            @stubs := $rtca.apply();
        }

        # Some things we only do if we weren't already composed once, like
        # building the MRO.
        my $was_composed := $!composed;
        unless $!composed {
            if self.parents($obj, :local(1)) == 0 && self.has_default_parent_type && self.name($obj) ne 'Mu' {
                self.add_parent($obj, self.get_default_parent_type);
            }
            self.compute_mro($obj);
            $!composed := 1;
        }

        # Incorporate any new multi candidates (needs MRO built).
        self.incorporate_multi_candidates($obj);

        # Compose remaining attributes from roles.
        self.compose_attributes($obj, :$compiler_services);

        # Set up finalization as needed.
        self.setup_finalization($obj);

        # Test the remaining stubs
        for @stubs -> %data {
            if !has_method(%data<target>, %data<name>) {
                nqp::die("Method '" ~ %data<name> ~ "' must be implemented by " ~
                         %data<target>.HOW.name(%data<target>) ~
                         " because it is required by roles: " ~
                         nqp::join(", ", %data<needed>) ~ ".");
            }
        }

        # See if we have a Bool method other than the one in the top type.
        # If not, all it does is check if we have the type object.
        unless self.get_boolification_mode($obj) != 0 {
            my $i := 0;
            my @mro := self.mro($obj);
            while $i < +@mro {
                my $ptype := @mro[$i];
                last if nqp::existskey(nqp::hllize($ptype.HOW.method_table($ptype)), 'Bool');
                last if nqp::can($ptype.HOW, 'submethod_table') &&
                    nqp::existskey(nqp::hllize($ptype.HOW.submethod_table($ptype)), 'Bool');
                $i := $i + 1;
            }
            if $i + 1 == +@mro {
                self.set_boolification_mode($obj, 5)
            }
        }

        # If there's a FALLBACK method, register something to forward calls to it.
        my $FALLBACK := self.find_method($obj, 'FALLBACK', :no_fallback);
        if !nqp::isnull($FALLBACK) && nqp::defined($FALLBACK) {
            self.add_fallback($obj,
                sub ($obj, str $name) {
                    $name ne 'sink' && $name ne 'CALL-ME'
                },
                sub ($obj, str $name) {
                    -> $inv, *@pos, *%named { $FALLBACK($inv, $name, |@pos, |%named) }
                });
        }

        # This isn't an augment.
        unless $was_composed {

            # Create BUILDPLAN.
            self.create_BUILDPLAN($obj);

            # Attempt to auto-generate a BUILDALL method. We can
            # only auto-generate a BUILDALL method if we have compiler
            # services. If we don't, then BUILDALL will fall back to the
            # one in Mu, which will iterate over the BUILDALLPLAN.
            if nqp::isconcrete($compiler_services) {

                # Class does not appear to have a BUILDALL yet
                unless nqp::existskey(nqp::hllize($obj.HOW.submethod_table($obj)),'BUILDALL')
                  || nqp::existskey(nqp::hllize($obj.HOW.method_table($obj)),'BUILDALL') {
                    my $builder := nqp::findmethod(
                      $compiler_services,'generate_buildplan_executor');
                    my $method :=
                      $builder($compiler_services,$obj,self.BUILDALLPLAN($obj));

                    # We have a generated BUILDALL submethod, so install!
                    unless $method =:= NQPMu {
                        $method.set_name('BUILDALL');
                        self.add_method($obj,'BUILDALL',$method);
                    }
                }
            }

            # Compose the representation
            self.compose_repr($obj);
        }

        # Publish type and method caches.
        self.publish_type_cache($obj);
        self.publish_method_cache($obj);
        self.publish_boolification_spec($obj);
        self.publish_container_spec($obj);

        # Compose the meta-methods.
        self.compose_meta_methods($obj);

#?if !moar
        # Compose invocation protocol.
        self.compose_invocation($obj);
#?endif

        self.'!refresh_archetypes'($obj);

        $obj
    }

    method roles($obj, :$local, :$transitive = 1, :$mro = 0) {
        my @result := self.roles-ordered($obj, @!roles, :$transitive, :$mro);
        unless $local {
            my $first := 1;
            for self.mro($obj) {
                if $first {
                    $first := 0;
                    next;
                }
                for $_.HOW.roles($_, :$transitive, :$mro, :local(1)) {
                    @result.push($_);
                }
            }
        }
        @result
    }

    method role_typecheck_list($obj) {
        $!composed ?? @!role_typecheck_list !! self.roles_to_compose($obj)
    }

    method is_composed($obj) {
        $!composed
    }

    # Stuff for junctiony dispatch fallback.
    my $junction_type;
    my $junction_autothreader;
    method setup_junction_fallback($type, $autothreader) {
#?if !moar
        nqp::setmethcacheauth($type, 0);
#?endif
        $junction_type := $type;
        $junction_autothreader := $autothreader;
    }

    # Handles the various dispatch fallback cases we have.
    method find_method_fallback($obj, $name, :$local = 0) {
        # If the object is a junction, need to do a junction dispatch.
        if nqp::istype($obj.WHAT, $junction_type) && $junction_autothreader {
            my $p6name := nqp::hllizefor($name, 'Raku');
            return -> *@pos_args, *%named_args {
                # Fallback on an undefined junction means no method found.
                nqp::isconcrete(@pos_args[0])
                    ?? $junction_autothreader($p6name, |@pos_args, |%named_args)
                    !! nqp::null()
            };
        }

        # Consider other fallbacks, if we have any.
        for @!fallbacks {
            if ($_<cond>)($obj, $name) {
                return ($_<calc>)($obj, $name);
            }
        }

        unless $local {
            my @mro := self.mro($obj);
            my $i := 0;
            while ++$i < +@mro {
                my $parent := @mro[$i];
                if nqp::can($parent.HOW, 'find_method_fallback')
                    && !nqp::isnull(my $fallback := $parent.HOW.find_method_fallback($obj, $name, :local)) {
                    return $fallback
                }
            }
        }

        # Otherwise, didn't find anything.
        nqp::null()
    }

    # Does the type have any fallbacks?
    method has_fallbacks($obj, :$local = 0) {
        return 1 if nqp::istype($obj, $junction_type) || +@!fallbacks;
        unless $local {
            my $i := 0;
            my @mro := self.mro($obj);
            while ++$i < +@mro {
                my $parent := @mro[$i];
                return 1 if nqp::can($parent.HOW, 'has_fallbacks') && $parent.HOW.has_fallbacks($obj, :local)
            }
        }
        0
    }

    method set_pun_source($obj, $role) {
        $!pun_source := nqp::decont($role);
        $!is_pun := 1;
    }

    method is_pun($obj) {
        $!is_pun
    }

    method pun_source($obj) {
        $!pun_source
    }

    method instantiate_generic($obj, $type_environment) {
        return $obj if nqp::isnull(my $type-env-type := Perl6::Metamodel::Configuration.type_env_from($type_environment));
        $type-env-type.cache($obj, { $obj.INSTANTIATE-GENERIC($type-env-type) });
    }

#?if moar
    nqp::dispatch('boot-syscall', 'dispatcher-register', 'raku-class-archetypes', -> $capture {
        # Returns archetypes of a class or a class instance
        # Dispatcher arguments:
        # ClassHOW object
        # invocator
        my $how := nqp::captureposarg($capture, 0);

        my $track-how := nqp::dispatch('boot-syscall', 'dispatcher-track-arg', $capture, 0);
        nqp::dispatch('boot-syscall', 'dispatcher-guard-concreteness', $track-how);

        unless nqp::isconcrete($how) {
            nqp::dispatch('boot-syscall', 'dispatcher-delegate', 'boot-code-constant', $archetypes-ng);
        }

        my $obj := nqp::captureposarg($capture, 1);
        my $track-obj := nqp::dispatch('boot-syscall', 'dispatcher-track-arg', $capture, 1);
        nqp::dispatch('boot-syscall', 'dispatcher-guard-concreteness', $track-obj);
        nqp::dispatch('boot-syscall', 'dispatcher-guard-type', $track-obj);

        if nqp::isconcrete_nd($obj) && nqp::iscont($obj) {
            my $Scalar := nqp::gethllsym('Raku', 'Scalar');
            my $track-value := nqp::dispatch('boot-syscall', 'dispatcher-track-attr', $track-obj, $Scalar, '$!value');
            nqp::dispatch('boot-syscall', 'dispatcher-guard-concreteness', $track-value);
            nqp::dispatch('boot-syscall', 'dispatcher-guard-type', $track-value);
            $obj := nqp::getattr($obj, $Scalar, '$!value');
        }

        my $can-is-generic := !nqp::isnull($obj) && nqp::can($obj, 'is-generic');
        my $atype;

        if nqp::isconcrete($obj) && $can-is-generic {
            # If invocant of .HOW.archetypes is a concrete object implementing 'is-generic' method then method outcome
            # is the ultimate result. But we won't cache it in type's HOW $!archetypes.
            nqp::dispatch('boot-syscall', 'dispatcher-delegate', 'boot-code-constant',
                nqp::dispatch('boot-syscall', 'dispatcher-insert-arg-literal-obj',
                    nqp::dispatch('boot-syscall', 'dispatcher-drop-arg',
                        nqp::dispatch('boot-syscall', 'dispatcher-drop-arg', $capture, 1),
                        0),
                    0, { $obj.is-generic ?? $archetypes-g !! $archetypes-ng }));
        }
        else {
            my $track-archetypes-attr :=
                nqp::dispatch('boot-syscall', 'dispatcher-track-attr',
                            $track-how, Perl6::Metamodel::ClassHOW, '$!archetypes');
            nqp::dispatch('boot-syscall', 'dispatcher-guard-literal', $track-archetypes-attr);

            $atype := nqp::getattr($how, Perl6::Metamodel::ClassHOW, '$!archetypes');

            unless nqp::isconcrete($atype) {
                # * If we still don't have an archetypes object then it means HOW doesn't know its archetypes yet. Therefore
                #   whatever we determine here is type's ultimate archetypes.
                # * Also, since we've taken care of a concrete object case then here 'is-generic' is invoked on the type
                #   itself, not an instance of it.
                $atype := $can-is-generic && $obj.is-generic ?? $archetypes-g !! $archetypes-ng;
                nqp::scwbdisable();
                nqp::getattr($how, Perl6::Metamodel::ClassHOW, '$!archt-lock').protect({
                    nqp::bindattr($how, Perl6::Metamodel::ClassHOW, '$!archetypes', $atype);
                });
                nqp::scwbenable();
            }

            nqp::dispatch('boot-syscall', 'dispatcher-delegate', 'boot-constant',
                nqp::dispatch('boot-syscall', 'dispatcher-insert-arg-literal-obj', $capture, 0, $atype));
        }
    });
#?endif
}

# vim: expandtab sw=4
