# Graphene Erlang/OTP
Copyright 2020 Ericsson AB

All Rights Reserved

The files contained in this repository is *not* open source, as in that
the source is licensed in a permissive license.

This repo is used as a starting point in getting Erlang/OTP to run in
Graphene SGX and for easier getting help from the Graphene developers in
making Erlang run in Graphene SGX.

## Prerequisites
Ubuntu 18.04

SGX driver installed (we use the DCAP version)

Probably some prerequisites to make Erlang/OTP build.

## Building
Regular build:
```
GRAPHENEDIR=[PATH TO GRAPHENE] SGX=1 make
```
Debug build:
```
GRAPHENEDIR=[PATH TO GRAPHENE] SGX=1 DEBUG=1 make
```

## Running
Running Erlang/OTP in Graphene is tricky (we can't yet).

Reducing the super carrier allocator by using the parameter `+MIscs 32`
ensures that Erlang/OTP doesn't allocate too much memory.

Using `+Meamin` can also reduce memory usage.

Try running the following with the suggested parameters above.
```
SGX=1 ./pal_loader erlexec.manifest
```

If you want to try running Erlang/OTP without interactive mode the following
can be run (remember to add the parameters)

```
SGX=1 ./pal_loader erlexec.manifest -noshell -s hello init -s init stop
```

