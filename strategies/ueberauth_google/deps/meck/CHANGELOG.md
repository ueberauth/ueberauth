# Change Log

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog], and this project adheres to
[Semantic Versioning].

## [Unreleased]

## [0.9.2] - 2021-03-06

### Fixed

- Fix a Dialyzer warning on OTP 24 [\#223](https://github.com/eproxus/meck/pull/223)

## [0.9.1] - 2021-02-17

### Fixed

- Module references in type specs were not included when renaming modules [\#206](https://github.com/eproxus/meck/issues/206)
- The passthrough clause was not always the last clause in an expect with multiple clauses [\#216](https://github.com/eproxus/meck/pull/216)

## [0.9.0] - 2020-06-25

### Added

- Support Erlang 23.0 [8c16751](https://github.com/eproxus/meck/commit/8c16751613c7e4ed594e0675004b1c8f68ea8ddd)
- Add a new function `mocked/0` that returns which modules are currently mocked [\#210](https://github.com/eproxus/meck/pull/210)

### Changed

- Validate the options being passed to meck:new [\#204](https://github.com/eproxus/meck/pull/204)

### Fixed

- Do not attempt to generate dependencies when mocking [9b3ce75](https://github.com/eproxus/meck/commit/9b3ce754bd69e84127f82d482b8b23b22f7bf866)
- Add compiler application to dependencies [\#209](https://github.com/eproxus/meck/pull/209)
- meck:ret_spec() opaqueness violates documented usage patterns [\#212](https://github.com/eproxus/meck/issues/212)

## [0.8.13] - 2019-01-08

### Removed

- Remove compatibility for Erlang R15 and R16 [\#198](https://github.com/eproxus/meck/issues/198)

### Fixed

- Crash when mocking Elixir 1.8-rc.0 compiled module [\#201](https://github.com/eproxus/meck/issues/201)
- Exclude from\_core option from compile\_info when compiling [\#202](https://github.com/eproxus/meck/pull/202) ([josevalim](https://github.com/josevalim))
- Isolate backup \*.coverdata from other beam instances [\#200](https://github.com/eproxus/meck/pull/200) ([dcsommer](https://github.com/dcsommer))


## [0.8.12] - 2018-08-08

### Fixed

- History item is not kept while module compiler is running [\#194](https://github.com/eproxus/meck/issues/194)

## [0.8.11] - 2018-07-12

### Fixed

- OTP 21 compatibility when using stack traces [\#193](https://github.com/eproxus/meck/pull/193) ([massemanet](https://github.com/massemanet))

## [0.8.10] - 2018-06-26

### Added

- Support Erlang/OTP 21.0 [\#190](https://github.com/eproxus/meck/pull/190) ([michalwski](https://github.com/michalwski))
- Add meck:expects/1,2 [\#187](https://github.com/eproxus/meck/pull/187) ([elbrujohalcon](https://github.com/elbrujohalcon))

## [0.8.9] - 2017-11-27

### Changed

- Migrate to Rebar 3 and rebar3\_hex [\#155](https://github.com/eproxus/meck/issues/155)

### Fixed

- Support running meck with modules built with '+deterministic' compile… [\#185](https://github.com/eproxus/meck/pull/185) ([nablaa](https://github.com/nablaa))
- How do I run coverage results after using meck? [\#181](https://github.com/eproxus/meck/issues/181)
- Fix for Rebar 2.x.y on secondary arches [\#183](https://github.com/eproxus/meck/pull/183) ([lemenkov](https://github.com/lemenkov))

## [0.8.8] - 2017-08-29

### Changed

- Always add debug\_info to compile opts for mocks [\#180](https://github.com/eproxus/meck/pull/180) ([ericentin](https://github.com/ericentin))

### Fixed

- `{:error, {:no\_abstract\_code, ...}}` with Elixir 1.5.0-rc.0 and Erlang 20.0 [\#179](https://github.com/eproxus/meck/issues/179)


## [0.8.7] - 2017-06-29

### Fixed

- Remove dialyzer attributes when creating mock \(Erlang 20.0\) [\#178](https://github.com/eproxus/meck/issues/178)

## [0.8.6] - 2017-06-28

### Fixed

- Remove dialyzer attributes when creating mock [3b772d0](https://github.com/eproxus/meck/commit/3b772d0afc7dd3e7fcae4f256f7728e9975fb412)

## [0.8.5] - 2017-06-28

### Added

- Support Erlang 20 [\#175](https://github.com/eproxus/meck/issues/175)
- Support Erlang 19 [\#168](https://github.com/eproxus/meck/pull/168) ([WramblinWreck](https://github.com/WramblinWreck))
- Add meck:get\_state/0, meck:reset\_state/0 [\#125](https://github.com/eproxus/meck/issues/125)
- Add `meck:result/4-5` that returns the result value of a particular function [\#163](https://github.com/eproxus/meck/pull/163) ([amutake](https://github.com/amutake))

### Deprecated

- Deprecate history and provide history digging functions instead  [\#85](https://github.com/eproxus/meck/issues/85)
- fix \#88 [\#162](https://github.com/eproxus/meck/pull/162) ([yutopp](https://github.com/yutopp))

### Fixed

- Mocked module will return empty function clause error [\#167](https://github.com/eproxus/meck/issues/167)
- Deleting an expectation in passthrough mode does not restore original function [\#88](https://github.com/eproxus/meck/issues/88)
- Passthrough crashes without +debug\_info [\#14](https://github.com/eproxus/meck/issues/14)
- fix behavio\(u\)r attributes validation on Erlang R20 [\#176](https://github.com/eproxus/meck/pull/176) ([RoadRunnr](https://github.com/RoadRunnr))
- Fix errors in capture/5, capture/6 documentation [\#172](https://github.com/eproxus/meck/pull/172) ([marco-m](https://github.com/marco-m))
- Fix eunit compile failure on Erlang 17+ \(hamcrest\) [\#161](https://github.com/eproxus/meck/pull/161) ([marco-m](https://github.com/marco-m))

## [0.8.4] - 2015-12-29

### Added

- Add merge\_expects option to meck\_proc [\#153](https://github.com/eproxus/meck/pull/153) ([edgurgel](https://github.com/edgurgel))

### Changed

- Update 'problematic modules list' [\#156](https://github.com/eproxus/meck/pull/156) ([lilrooness](https://github.com/lilrooness))
- Document the caveat with mocking module-local calls. [\#145](https://github.com/eproxus/meck/pull/145) ([bpuzon](https://github.com/bpuzon))

### Fixed

- FIX: optional\_callbacks [\#151](https://github.com/eproxus/meck/pull/151) ([soranoba](https://github.com/soranoba))
- Fix race condition between meck:unload/1 and calls to the mocked module [\#150](https://github.com/eproxus/meck/pull/150) ([dszoboszlay](https://github.com/dszoboszlay))

## [0.8.3] - 2015-06-09

### Added

- Support Erlang 18.0 [\#139](https://github.com/eproxus/meck/pull/139) ([gomoripeti](https://github.com/gomoripeti))
- Allow hiding 'on\_load' attribute. [\#131](https://github.com/eproxus/meck/pull/131) ([rlipscombe](https://github.com/rlipscombe))

### Changed

- Removed test and doc from target all in Makefile [\#126](https://github.com/eproxus/meck/pull/126) ([jfacorro](https://github.com/jfacorro))
- Fix typo [\#143](https://github.com/eproxus/meck/pull/143) ([derek121](https://github.com/derek121))
- Run tests in travis [\#138](https://github.com/eproxus/meck/pull/138) ([gomoripeti](https://github.com/gomoripeti))

### Fixed

- Please document that modules can be not meck'able [\#135](https://github.com/eproxus/meck/issues/135)
- crypto module [\#59](https://github.com/eproxus/meck/issues/59)
- Fix variable exported from case [\#128](https://github.com/eproxus/meck/pull/128) ([hazardfn](https://github.com/hazardfn))


## [0.8.2] - 2014-05-05

### Added

- Suport Erlang 17.0 and Erlang R16B03-1 [\#118](https://github.com/eproxus/meck/pull/118) ([myers](https://github.com/myers))

  Add Erlang 17.0 to the test matrix [\#122](https://github.com/eproxus/meck/pull/122) ([myers](https://github.com/myers))
- Implicit new [\#80](https://github.com/eproxus/meck/issues/80)
- Should return compilation errors [\#33](https://github.com/eproxus/meck/issues/33)
- Better documentation [\#79](https://github.com/eproxus/meck/issues/79)

### Changed

- Put non-strict option in the README.md [\#117](https://github.com/eproxus/meck/issues/117)
- Split tests into several test suites [\#83](https://github.com/eproxus/meck/issues/83)

### Fixed

- With a bogus test instantiator, meck fails with {error, enoent} in meck\_cover:read\_cover\_file/1 [\#114](https://github.com/eproxus/meck/issues/114)
- Unable to mock lists module [\#87](https://github.com/eproxus/meck/issues/87)
- Do not consider a 3-tuple return value as an exception [\#113](https://github.com/eproxus/meck/pull/113) ([lucafavatella](https://github.com/lucafavatella))


## [0.8.1] - 2013-08-29

### Fixed

- Attribute errors [\#110](https://github.com/eproxus/meck/pull/110) ([twonds](https://github.com/twonds))

## [0.8] - 2013-08-17

### Added

- Support R16B [\#100](https://github.com/eproxus/meck/pull/100) ([rufrozen](https://github.com/rufrozen))
- Capture argument [\#86](https://github.com/eproxus/meck/issues/86)

  Feature/capture [\#97](https://github.com/eproxus/meck/pull/97) ([horkhe](https://github.com/horkhe))
- Wait for a number of function calls [\#81](https://github.com/eproxus/meck/issues/81)

  Wait for a number of calls feature \(\#81\) [\#99](https://github.com/eproxus/meck/pull/99) ([horkhe](https://github.com/horkhe))
- Mocking of parameterized modules [\#4](https://github.com/eproxus/meck/issues/4)
- Allow calling original function from within expect fun [\#2](https://github.com/eproxus/meck/issues/2)
- Make remote\_setup more robust [\#109](https://github.com/eproxus/meck/pull/109) ([i11](https://github.com/i11))
- Implement 'implicit new' feature \#80 [\#104](https://github.com/eproxus/meck/pull/104) ([horkhe](https://github.com/horkhe))
- Make `undefined\_module` error contain module name [\#96](https://github.com/eproxus/meck/pull/96) ([horkhe](https://github.com/horkhe))
- Introduce support for matchers: [\#89](https://github.com/eproxus/meck/pull/89) ([horkhe](https://github.com/horkhe))
- Feature/file bif passthrough [\#84](https://github.com/eproxus/meck/pull/84) ([horkhe](https://github.com/horkhe))
- Two new options for meck [\#77](https://github.com/eproxus/meck/pull/77) ([norton](https://github.com/norton))
- Feature/honest mocks [\#75](https://github.com/eproxus/meck/pull/75) ([horkhe](https://github.com/horkhe))
- Feature/new exception syntax [\#74](https://github.com/eproxus/meck/pull/74) ([horkhe](https://github.com/horkhe))
- Extended expect syntax and more [\#73](https://github.com/eproxus/meck/pull/73) ([horkhe](https://github.com/horkhe))
- Introduce 'stub\_all' option [\#78](https://github.com/eproxus/meck/pull/78) ([horkhe](https://github.com/horkhe))
- Support for location included in stack traces in Erlang R15 [\#52](https://github.com/eproxus/meck/pull/52) ([bjnortier](https://github.com/bjnortier))

### Changed

- Make `passthrough/1` and `func/1` into a `ret\_spec`and func [\#91](https://github.com/eproxus/meck/pull/91) ([horkhe](https://github.com/horkhe)
- Refactor meck into smaller functional modules [\#82](https://github.com/eproxus/meck/pull/82) ([horkhe](https://github.com/horkhe))

### Removed

- R16A preview - parameterized modules are no longer supported [\#94](https://github.com/eproxus/meck/issues/94)
- Remove unsupported option from the app.src file [\#101](https://github.com/eproxus/meck/pull/101) ([amiramix](https://github.com/amiramix))
- Remove parametrized module test [\#95](https://github.com/eproxus/meck/pull/95) ([norton](https://github.com/norton))

### Fixed

- Warning from reltool on unexpected item `build\_dependencies` [\#92](https://github.com/eproxus/meck/issues/92)
- http://eproxus.github.io/meck 404 [\#103](https://github.com/eproxus/meck/issues/103)
- meck eunit tests fail on R15B [\#51](https://github.com/eproxus/meck/issues/51)
- meck:new fails if running in embedded mode and module not loaded [\#35](https://github.com/eproxus/meck/issues/35)
- Support meck:expect with improper list mock data [\#102](https://github.com/eproxus/meck/pull/102) ([adbl](https://github.com/adbl))
- Fix failing build. [\#98](https://github.com/eproxus/meck/pull/98) ([cmeiklejohn](https://github.com/cmeiklejohn))
- fix path of rebar [\#69](https://github.com/eproxus/meck/pull/69) ([yamt](https://github.com/yamt))

## [0.7.2] - 2012-05-06

### Added

- Remove Erlang R15B support  [\#54](https://github.com/eproxus/meck/pull/54) ([michaelklishin](https://github.com/michaelklishin))
- Mocking of sticky modules [\#7](https://github.com/eproxus/meck/issues/7)
- Rz passthrough cover [\#56](https://github.com/eproxus/meck/pull/56) ([rzezeski](https://github.com/rzezeski))
- Mock parametrized modules [\#55](https://github.com/eproxus/meck/pull/55) ([shino](https://github.com/shino))
- Clean test directory [\#50](https://github.com/eproxus/meck/pull/50) ([norton](https://github.com/norton))
- New features - pid in history and count\_calls and wildcard\_count\_calls functions [\#40](https://github.com/eproxus/meck/pull/40) ([daha](https://github.com/daha))
- Include meck:new/2 arguments in errors [\#39](https://github.com/eproxus/meck/pull/39) ([legoscia](https://github.com/legoscia))
- .travis.yml config without rebar [\#38](https://github.com/eproxus/meck/pull/38) ([wardbekker](https://github.com/wardbekker))
- Filter out parse\_transforms from compilation options [\#32](https://github.com/eproxus/meck/pull/32) ([djnym](https://github.com/djnym))

### Changed

- remove repetition; typo [\#57](https://github.com/eproxus/meck/pull/57) ([Erkan-Yilmaz](https://github.com/Erkan-Yilmaz))
- Improved tests: Added an ok in the end of the tests that use a helper function with asserts [\#43](https://github.com/eproxus/meck/pull/43) ([daha](https://github.com/daha))
- Making all the test funs in the foreach in meck\_test\_/0 fully qualified funs [\#44](https://github.com/eproxus/meck/pull/44) ([daha](https://github.com/daha))

### Removed

- Remove IDE project artifacts [\#46](https://github.com/eproxus/meck/pull/46) ([xenolinguist](https://github.com/xenolinguist))
- Remove Erlang R13B support  [\#54](https://github.com/eproxus/meck/pull/54) ([michaelklishin](https://github.com/michaelklishin))

### Fixed

- dialyzer warnings with meck \(73c0b3e\) [\#58](https://github.com/eproxus/meck/issues/58)
- Inconsistency in documentation [\#49](https://github.com/eproxus/meck/issues/49)
- meck:unload/0 sometimes crashes [\#48](https://github.com/eproxus/meck/issues/48)
- Add test/cover\_test\_module.beam to rebar.config's clean files [\#47](https://github.com/eproxus/meck/issues/47)
- Fix typo in no\_passthrough\_cover atom [\#62](https://github.com/eproxus/meck/pull/62) ([garret-smith](https://github.com/garret-smith))
- Verify history/2 returns events in the correct order & fix to flaky history\_by\_pid\_/1 test [\#42](https://github.com/eproxus/meck/pull/42) ([daha](https://github.com/daha))

## [0.7.1] - 2011-07-18

### Fixed

- Can I call original function with different arguments? [\#30](https://github.com/eproxus/meck/issues/30)

## [0.7] - 2011-07-13

### Added

- Enable mocking of sticky modules \(not used by code\_server\) [\#29](https://github.com/eproxus/meck/pull/29) ([xenolinguist](https://github.com/xenolinguist))

## [0.6.3] - 2011-06-30

### Changed

- Interface inconsistency [\#8](https://github.com/eproxus/meck/issues/8)

## [0.6.2] - 2011-06-09

- Fix re adding shortcut expects [9b8934a](https://github.com/eproxus/meck/commit/9b8934a33e4a1d427a25e9a0d128f728ee1ab9b9)
- Fix returning of opaque terms in shortcut expectations [b1904a2](https://github.com/eproxus/meck/commit/b1904a2fb7f9d7d553cf9392cab742683d411066)

## [0.6.1] - 2011-06-08

### Added

- use localhost for remote test rather than hostname [\#27](https://github.com/eproxus/meck/pull/27) ([joewilliams](https://github.com/joewilliams))

### Fixed

- Makefile requires local rebar and documentation says rebar on path [\#28](https://github.com/eproxus/meck/issues/28)


## [0.6] - 2011-05-25

### Added

- Add `loop/4` expect function [8d86012](https://github.com/eproxus/meck/commit/8d86012c851b7ee6eb26831f1822129ee82c8f2e)
- Add `sequence/4` expect function [35de01e](https://github.com/eproxus/meck/commit/35de01eca6b1d952997b86638f33f180461b38f5)

## [0.5.1] - 2011-05-23

### Changed

- Replace fail_on_warning with warnings_as_errors [ddd9e3b](https://github.com/eproxus/meck/commit/ddd9e3bcc896d3cf8092db341d57acfa2208fe8a)

## [0.5] - 2011-04-12

### Added

- Add meck:received/3 API for easier history checking [\#23](https://github.com/eproxus/meck/pull/23) ([mbbx6spp](https://github.com/mbbx6spp))

### Fixed

- dialyzer unmatched return errors [\#24](https://github.com/eproxus/meck/issues/24)

[Unreleased]: https://github.com/eproxus/meck/compare/0.9.2...HEAD
[0.9.2]: https://github.com/eproxus/meck/compare/0.9.1...0.9.2
[0.9.1]: https://github.com/eproxus/meck/compare/0.9.0...0.9.1
[0.9.0]: https://github.com/eproxus/meck/compare/0.8.13...0.9.0
[0.8.13]: https://github.com/eproxus/meck/compare/0.8.12...0.8.13
[0.8.12]: https://github.com/eproxus/meck/compare/0.8.11...0.8.12
[0.8.11]: https://github.com/eproxus/meck/compare/0.8.10...0.8.11
[0.8.10]: https://github.com/eproxus/meck/compare/0.8.9...0.8.10
[0.8.9]: https://github.com/eproxus/meck/compare/0.8.8...0.8.9
[0.8.8]: https://github.com/eproxus/meck/compare/0.8.7...0.8.8
[0.8.7]: https://github.com/eproxus/meck/compare/0.8.6...0.8.7
[0.8.6]: https://github.com/eproxus/meck/compare/0.8.5...0.8.6
[0.8.5]: https://github.com/eproxus/meck/compare/0.8.4...0.8.5
[0.8.4]: https://github.com/eproxus/meck/compare/0.8.3...0.8.4
[0.8.3]: https://github.com/eproxus/meck/compare/0.8.2...0.8.3
[0.8.2]: https://github.com/eproxus/meck/compare/0.8.1...0.8.2
[0.8.1]: https://github.com/eproxus/meck/compare/0.8...0.8.1
[0.8]: https://github.com/eproxus/meck/compare/0.7.2...0.8
[0.7.2]: https://github.com/eproxus/meck/compare/0.7.1...0.7.2
[0.7.1]: https://github.com/eproxus/meck/compare/0.7...0.7.1
[0.7]: https://github.com/eproxus/meck/compare/0.6.3...0.7
[0.6.3]: https://github.com/eproxus/meck/compare/0.6.2...0.6.3
[0.6.2]: https://github.com/eproxus/meck/compare/0.6.1...0.6.2
[0.6.1]: https://github.com/eproxus/meck/compare/0.6...0.6.1
[0.6]: https://github.com/eproxus/meck/compare/0.5.1...0.6
[0.5.1]: https://github.com/eproxus/meck/compare/0.5...0.5.1
[0.5]: https://github.com/eproxus/meck/releases/tag/0.5

[Keep a Changelog]: https://keepachangelog.com/en/1.0.0/
[Semantic Versioning]: https://semver.org/spec/v2.0.0.html
