#
# This file is based on the Graphene example file for nginx.
#
# Building the manifest for Erlang:
#
# - make                  Building for Linux
# - make DEBUG=1          Building for Linux, with Graphene debug output
# - make SGX=1            Building for SGX
# - make SGX=1 DEBUG=1    Building for SGX, with Graphene debug output
#
# Use `make clean` to remove Graphene-generated files.
#
# Use `make distclean` to further remove the Erlang tarball, source code,
# and installation.

THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

INSTALL_DIR ?= $(THIS_DIR)install
ERLANG_SRC ?= $(THIS_DIR)otp_src_22.3
ERLANG_CHECKSUM ?= 5c35b952808fa933ca95a9d259818aee27cb17ca96067da0fda2f035259ee612

BIN_DIR ?= $(INSTALL_DIR)/lib/erlang/erts-10.7/bin
ERLEXEC_EXECUTABLE ?= $(BIN_DIR)/erlexec
# ERLANG_EXECUTABLES ?= $(BIN_DIR)/beam.smp $(ERLANG_MAIN_EXECUTABLE)
BEAMSMP_EXECUTABLE ?= $(BIN_DIR)/beam.smp

# Mirrors for downloading the Erlang source code
ERLANG_MIRRORS ?= \
	http://erlang.org/download/

# Relative path to Graphene root
GRAPHENEDIR ?= $(THIS_DIR)../..
SGX_SIGNER_KEY ?= $(GRAPHENEDIR)/Pal/src/host/Linux-SGX/signer/enclave-key.pem

ifeq ($(DEBUG),1)
GRAPHENEDEBUG = inline
else
GRAPHENEDEBUG = none
endif

.PHONY: all
all: $(BIN_DIR)/erlexec hello.beam erlexec.manifest \
	beam.smp.manifest \
	erl_child_setup.manifest \
	pal_loader
ifeq ($(SGX),1)

# order matters, do beam first, then erlexec
all: erl_child_setup.manifest.sgx erl_child_setup.sig erl_child_setup.token \
	beam.smp.manifest.sgx beam.smp.sig beam.smp.token \
	erlexec.manifest.sgx erlexec.sig erlexec.token
endif

# The make targets for downloading and compiling the Erlang source code, and
# installing the binaries.
$(BIN_DIR)/erlexec: $(ERLANG_SRC)/configure
	cd $(ERLANG_SRC) && ./configure --prefix=$(abspath $(INSTALL_DIR))
	cd $(ERLANG_SRC) && $(MAKE)
	cd $(ERLANG_SRC) && $(MAKE) install

$(ERLANG_SRC)/configure: $(ERLANG_SRC).tar.gz
	tar -mxzf $<

$(ERLANG_SRC).tar.gz:
	$(GRAPHENEDIR)/Scripts/download --output $@ --sha256 $(ERLANG_CHECKSUM) $(foreach mirror,$(ERLANG_MIRRORS),--url $(mirror)/$(ERLANG_SRC).tar.gz)

# Erlang dependencies (generate from ldd):
#
# For SGX, the manifest needs to list all the libraries loaded during the
# execution, so that the signer can include the file checksums.
#
# The dependencies are generated from the ldd results.

# We need to replace Glibc dependencies with Graphene-specific Glibc. The Glibc
# binaries are already listed in the manifest template, so we can skip them
# from the ldd results
GLIBC_DEPS = linux-vdso /lib64/ld-linux-x86-64 libc libm librt libdl libutil libpthread

# Listing all the Erlang dependencies, besides Glibc libraries
.INTERMEDIATE: erlexec-ldd
erlexec-ldd: $(BIN_DIR)/erlexec
	@echo erlexec ldd analysis
	@for F in $^; do \
		ldd $$F >> $@ || exit 1; done

.INTERMEDIATE: beam_smp-ldd
beam_smp-ldd: $(BIN_DIR)/beam.smp
	@echo beam.smp ldd analysis
	@for F in $^; do \
		ldd $$F >> $@ || exit 1; done

.INTERMEDIATE: erl_child_setup-ldd
erl_child_setup-ldd: $(BIN_DIR)/erl_child_setup
	@echo erl_child_setup ldd analysis
	@for F in $^; do \
		ldd $$F >> $@ || exit 1; done

.INTERMEDIATE: erlexec-deps
erlexec-deps: erlexec-ldd
	@echo erlexec library dependancy extraction
	@cat $< | awk '{if ($$2 =="=>") {split($$1,s,/\./); print s[1]}}' \
		| sort | uniq | grep -v -x $(patsubst %,-e %,$(GLIBC_DEPS)) > $@

.INTERMEDIATE: beam_smp-deps
beam_smp-deps: beam_smp-ldd
	@echo beam.smp library dependancy extraction
	@cat $< | awk '{if ($$2 =="=>") {split($$1,s,/\./); print s[1]}}' \
		| sort | uniq | grep -v -x $(patsubst %,-e %,$(GLIBC_DEPS)) > $@

.INTERMEDIATE: erl_child_setup-deps
erl_child_setup-deps: erl_child_setup-ldd
	@echo erl_child_setup library dependancy extraction
	@cat $< | awk '{if ($$2 =="=>") {split($$1,s,/\./); print s[1]}}' \
		| sort | uniq | grep -v -x $(patsubst %,-e %,$(GLIBC_DEPS)) > $@

# Generating manifest rules for Erlang dependencies
.INTERMEDIATE: erlexec-trusted-libs
erlexec-trusted-libs: erlexec-deps
	@echo erlexec trusted library generation
	@BINFILE="$(BIN_DIR)/erlexec" && \
	for F in `cat erlexec-deps`; do \
		P=`ldd $$BINFILE | grep $$F | awk '{print $$3; exit}'`; \
		N=`echo $$F | tr --delete '-'`; \
		echo -n "sgx.trusted_files.$$N = file:$$P\\\\n"; \
	done > $@

.INTERMEDIATE: beam_smp-trusted-libs
beam_smp-trusted-libs: beam_smp-deps
	@echo beam.smp trusted library generation
	@BINFILE="$(BIN_DIR)/beam.smp" && \
	for F in `cat beam_smp-deps`; do \
		P=`ldd $$BINFILE | grep $$F | awk '{print $$3; exit}'`; \
		N=`echo $$F | tr --delete '-'`; \
		echo -n "sgx.trusted_files.$$N = file:$$P\\\\n"; \
	done > $@

.INTERMEDIATE: erl_child_setup-trusted-libs
erl_child_setup-trusted-libs: erl_child_setup-deps
	@echo erl_child_setup trusted library generation
	@BINFILE="$(BIN_DIR)/erl_child_setup" && \
	for F in `cat erl_child_setup-deps`; do \
		P=`ldd $$BINFILE | grep $$F | awk '{print $$3; exit}'`; \
		N=`echo $$F | tr --delete '-'`; \
		echo -n "sgx.trusted_files.$$N = file:$$P\\\\n"; \
	done > $@

# Original which won't work because erlexec-trusted-libs output an empty list
#erlexec.manifest: erlexec.manifest.template erlexec-trusted-libs
#	sed -e 's|$$(GRAPHENEDIR)|'"$(GRAPHENEDIR)"'|g' \
#		-e 's|$$(GRAPHENEDEBUG)|'"$(GRAPHENEDEBUG)"'|g' \
#		-e 's|$$(INSTALL_DIR)|'"$(INSTALL_DIR)"'|g' \
#		-e 's|$$(INSTALL_DIR_ABSPATH)|'"$(abspath $(INSTALL_DIR))"'|g' \
#		-e 's|$$(ERLANG_TRUSTED_LIBS)|'"`cat erlexec-trusted-libs`"'|g' \
#		$< > $@

erlexec.manifest: erlexec.manifest.template
	@echo creating erlexec.manifest from template
	sed -e 's|$$(GRAPHENEDIR)|'"$(GRAPHENEDIR)"'|g' \
		-e 's|$$(GRAPHENEDEBUG)|'"$(GRAPHENEDEBUG)"'|g' \
		-e 's|$$(INSTALL_DIR)|'"$(INSTALL_DIR)"'|g' \
		-e 's|$$(INSTALL_DIR_ABSPATH)|'"$(abspath $(INSTALL_DIR))"'|g' \
		-e 's|$$(ERLANG_TRUSTED_LIBS)||g' \
		$< > $@

beam.smp.manifest: beam.smp.manifest.template beam_smp-trusted-libs
	@echo creating beam.smp.manifest from template
	sed -e 's|$$(GRAPHENEDIR)|'"$(GRAPHENEDIR)"'|g' \
		-e 's|$$(GRAPHENEDEBUG)|'"$(GRAPHENEDEBUG)"'|g' \
		-e 's|$$(INSTALL_DIR)|'"$(INSTALL_DIR)"'|g' \
		-e 's|$$(INSTALL_DIR_ABSPATH)|'"$(abspath $(INSTALL_DIR))"'|g' \
		-e 's|$$(ERLANG_TRUSTED_LIBS)|'"`cat beam_smp-trusted-libs`"'|g' \
		$< > $@

# Original which won't work because erl_child_setup-trusted-libs output an empty list
#erl_child_setup.manifest: erl_child_setup.manifest.template erl_child_setup-trusted-libs
#	@echo creating erl_child_setup.manifest from template
#	sed -e 's|$$(GRAPHENEDIR)|'"$(GRAPHENEDIR)"'|g' \
#		-e 's|$$(GRAPHENEDEBUG)|'"$(GRAPHENEDEBUG)"'|g' \
#		-e 's|$$(INSTALL_DIR)|'"$(INSTALL_DIR)"'|g' \
#		-e 's|$$(INSTALL_DIR_ABSPATH)|'"$(abspath $(INSTALL_DIR))"'|g' \
#		-e 's|$$(ERLANG_TRUSTED_LIBS)|'"`cat erl_child_setup-trusted-libs`"'|g' \
#		$< > $@

erl_child_setup.manifest: erl_child_setup.manifest.template
	@echo creating erl_child_setup.manifest from template
	sed -e 's|$$(GRAPHENEDIR)|'"$(GRAPHENEDIR)"'|g' \
		-e 's|$$(GRAPHENEDEBUG)|'"$(GRAPHENEDEBUG)"'|g' \
		-e 's|$$(INSTALL_DIR)|'"$(INSTALL_DIR)"'|g' \
		-e 's|$$(INSTALL_DIR_ABSPATH)|'"$(abspath $(INSTALL_DIR))"'|g' \
		-e 's|$$(ERLANG_TRUSTED_LIBS)||g' \
		$< > $@

# Generating the SGX-specific manifest (erlexec.manifest.sgx), the enclave signature,
# and the token for enclave initialization.
erlexec.manifest.sgx: erlexec.manifest
	@echo creating erlexec sgx manifest
	$(GRAPHENEDIR)/Pal/src/host/Linux-SGX/signer/pal-sgx-sign \
		-libpal $(GRAPHENEDIR)/Runtime/libpal-Linux-SGX.so \
		-key $(SGX_SIGNER_KEY) \
		-manifest $< -output $@

beam.smp.manifest.sgx: beam.smp.manifest
	@echo creating beam.smp sgx manifest
	$(GRAPHENEDIR)/Pal/src/host/Linux-SGX/signer/pal-sgx-sign \
		-libpal $(GRAPHENEDIR)/Runtime/libpal-Linux-SGX.so \
		-key $(SGX_SIGNER_KEY) \
		-manifest $< -output $@

erl_child_setup.manifest.sgx: erl_child_setup.manifest
	@echo creating erl_child_setup sgx manifest
	$(GRAPHENEDIR)/Pal/src/host/Linux-SGX/signer/pal-sgx-sign \
		-libpal $(GRAPHENEDIR)/Runtime/libpal-Linux-SGX.so \
		-key $(SGX_SIGNER_KEY) \
		-manifest $< -output $@

erlexec.sig: erlexec.manifest.sgx
beam.smp.sig: beam.smp.manifest.sgx
erl_child_setup.sig: erl_child_setup.manifest.sgx

erlexec.token: erlexec.sig
	@echo creating erlexec signatures
	$(GRAPHENEDIR)/Pal/src/host/Linux-SGX/signer/pal-sgx-get-token \
		-output erlexec.token -sig erlexec.sig

beam.smp.token: beam.smp.sig
	@echo creating beam.smp signatures
	$(GRAPHENEDIR)/Pal/src/host/Linux-SGX/signer/pal-sgx-get-token \
		-output beam.smp.token -sig beam.smp.sig

erl_child_setup.token: erl_child_setup.sig
	@echo creating erl_child_setup signatures
	$(GRAPHENEDIR)/Pal/src/host/Linux-SGX/signer/pal-sgx-get-token \
		-output erl_child_setup.token -sig erl_child_setup.sig


hello.beam: hello.erl
	$(INSTALL_DIR)/bin/erlc $<


# Extra executables
pal_loader:
	ln -s $(GRAPHENEDIR)/Runtime/pal_loader $@

.PHONY: clean
clean:
	$(RM) *.manifest *.manifest.sgx *.token *.sig pal_loader OUTPUT result-* beam_smp-ldd erlexec-ldd erl_child_setup-ldd tmp hello.beam

.PHONY: distclean
distclean: clean
	$(RM) -r $(ERLANG_SRC).tar.gz $(ERLANG_SRC) $(INSTALL_DIR)
