#!/bin/sh
DoExitAsm ()
{ echo "An error occurred while assembling $1"; exit 1; }
DoExitLink ()
{ echo "An error occurred while linking $1"; exit 1; }
echo Assembling platform_impl
x86_64-win64-as --64 -o build/platform_impl.o   build/platform_impl.s
if [ $? != 0 ]; then DoExitAsm platform_impl; fi
