#!/bin/bash

$CUSTOM_C -c pinroi.c -o libpinroi.o
$CUSTOM_CC -c pinroi.c -o libpinroi-cc.o
ar rc libpinroi.a libpinroi.o
ar rc libpinroi-cc.a libpinroi-cc.o
ranlib libpinroi.a
ranlib libpinroi-cc.a

if [[ -z "${PIN_ROOT}" ]]; then
	echo "Please set PIN_ROOT."
	exit
fi

make obj-intel64/roitrace-mt.so
make obj-intel64/all-routine-mt.so
