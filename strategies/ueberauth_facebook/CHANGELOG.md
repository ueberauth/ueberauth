# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

* Require at least Ueberauth 0.7 due to changed builtin CSRF protection

## v0.8.2 - 2021-07-15

* Allow OAuth options to be configured from the connection
* Set default profile image to large

## v0.8.1 - 2020-03-02

* Handle errors from fetching the access token with an invalid/expired code
* Support OAuth2 version 2.0 library
* Set OAuth2 JSON library based on Ueberauth's JSON libray

## v0.8.0 - 2019-03-09

* Add option to specify scheme for user avatar URL
* Stop sending empty params to the Facebook auth dialog

## v0.7.0 - 2017-07-18

* Support `:appsecret_proof` parameter
* Set the required `:profile_fields` to get the email back

## v0.6.0 - 2016-12-27

* Support `:display` parameter
* Use OAuth2 0.8

## v0.5.0 - 2016-09-21

* Pin OAuth2 to 0.6 to avoid errors

## v0.4.0 - 2016-07-19

* Allow `:state` param to be configured

## v0.3.2 - 2016-02-15

* Fix support for auth_type

## v0.3.1 - 2016-02-10

* Add support for missing Locale parameter

## v0.3.0 - 2016-02-04

* Add support for auth_type
* Support for additional request variables

## v0.2.1 - 2015-12-11

* Add missing `profile_fields` parameter

## v0.2.0 - 2015-11-28

* Release to follow the Ueberauth 0.2.0 release

## v0.1.4 - 2015-11-18

* Added oauth2 and ueberauth to applications list

## v0.1.1 - 2015-11-16

* Fixed character encoding errors in Hex package

## v0.1.0 - 2015-11-16

* Initial strategy
