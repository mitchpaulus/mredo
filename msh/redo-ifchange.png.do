#!/usr/bin/env mshell
[redo-ifchange  `redo-ifchange.dot`]!
['dot' '-Tpng' `redo-ifchange.dot`]!
