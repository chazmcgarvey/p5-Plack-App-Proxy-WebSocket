
# This is not a Perl distribution, but it can build one using Dist::Zilla.

CPANM   = cpanm
DZIL    = dzil
PERL    = perl
PROVE   = prove

all: dist

bootstrap:
	$(CPANM) Dist::Zilla
	$(DZIL) authordeps --missing | $(CPANM)
	$(DZIL) listdeps --develop --missing | $(CPANM)

clean:
	$(DZIL) $@

dist:
	$(DZIL) build

test:
	$(PROVE) -l

.PHONY: all bootstrap clean dist test

