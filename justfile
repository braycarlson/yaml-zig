set shell := ["sh", "-c"]
set windows-shell := ["powershell.exe", "-c"]

[doc('Compile every artifact for Linux and Windows')]
check:
    zig build check

[doc('Run the continuous integration pipeline')]
ci:
    zig build ci
    zig build test:unit -Doptimize=safe

[doc('Run the yaml-test-suite: just conformance <data directory> [case]')]
conformance *arguments:
    zig build conformance -- {{ arguments }}

[doc('Build and run every example')]
example:
    zig build example

[doc('Format build.zig, the examples, and every source file')]
fmt:
    zig fmt build.zig examples src

[doc('Run a fuzzer: just fuzz <fuzzer> [seed]')]
fuzz *arguments:
    zig build fuzz -- {{ arguments }}

[doc('Lint build.zig, the examples, and every source file with tigerstyle-lsp')]
lint:
    tigerstyle-lsp check build.zig examples src --format concise

[default]
[doc('List every recipe')]
list:
    @just --list

[doc('Run every test suite and the format check')]
test:
    zig build test

[doc('Run the unit tests and the tidy check: just test-unit [filter]')]
test-unit filter="":
    zig build test:unit {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}
