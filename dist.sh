#!/bin/sh
 
set -e
./bootstrap
prove -v
make dist
scp logsender-`cat VERSION`.tar.gz oepdown@james:public_html/hin/
