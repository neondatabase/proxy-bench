#!/bin/sh
mkdir -p target
openssl req -new -x509 -days 265 -nodes -text -out target/proxy.crt -keyout target/proxy.key -subj "/CN=*.localtest.me" -addext "subjectAltName = DNS:*.localtest.me"
