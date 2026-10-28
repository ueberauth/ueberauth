

# The parse_trans application #

__Authors:__ Ulf Wiger ([`ulf@wiger.net`](mailto:ulf@wiger.net)).

Parse_transform utilities

[![Build Status](https://travis-ci.org/uwiger/parse_trans.svg)](https://travis-ci.com/github/uwiger/parse_trans)
[![Hex pm](http://img.shields.io/hexpm/v/parse_trans.svg?style=flat)](https://hex.pm/packages/parse_trans)


## Introduction ##

Parse_trans was written in order to capture some useful patterns in parse transformation
and code generation for Erlang.

Most notably, perhaps, the module [`exprecs`](http://github.com/uwiger/parse_trans/blob/master/doc/exprecs.md) generates standardized accessor
functions for records, and [`ct_expand`](http://github.com/uwiger/parse_trans/blob/master/doc/ct_expand.md) makes it possible to evaluate an
expression at compile-time and substitute the result as a compile-time constant.

Less known modules, perhaps:
* [`parse_trans_pp`](http://github.com/uwiger/parse_trans/blob/master/doc/parse_trans_pp.md) can be called with escript to pretty-print source from
  debug-compiled .beam files.
* [`parse_trans_codegen`](http://github.com/uwiger/parse_trans/blob/master/doc/parse_trans_codegen.md) provides pseudo-functions that can be used for
  simple code generation.
* [`parse_trans`](http://github.com/uwiger/parse_trans/blob/master/doc/parse_trans.md) provides various helper functions for traversing code and
  managing complex parse transforms


## Modules ##


<table width="100%" border="0" summary="list of modules">
<tr><td><a href="http://github.com/uwiger/parse_trans/blob/master/doc/ct_expand.md" class="module">ct_expand</a></td></tr>
<tr><td><a href="http://github.com/uwiger/parse_trans/blob/master/doc/exprecs.md" class="module">exprecs</a></td></tr>
<tr><td><a href="http://github.com/uwiger/parse_trans/blob/master/doc/parse_trans.md" class="module">parse_trans</a></td></tr>
<tr><td><a href="http://github.com/uwiger/parse_trans/blob/master/doc/parse_trans_codegen.md" class="module">parse_trans_codegen</a></td></tr>
<tr><td><a href="http://github.com/uwiger/parse_trans/blob/master/doc/parse_trans_mod.md" class="module">parse_trans_mod</a></td></tr>
<tr><td><a href="http://github.com/uwiger/parse_trans/blob/master/doc/parse_trans_pp.md" class="module">parse_trans_pp</a></td></tr></table>

