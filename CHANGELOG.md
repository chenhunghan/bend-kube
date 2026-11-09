# Changelog

## [0.5.4](https://github.com/chenhunghan/bend-kube/compare/v0.5.3...v0.5.4) (2026-11-09)


### Bug Fixes

* leadership fence on every controller request ([#17](https://github.com/chenhunghan/bend-kube/issues/17)) ([888c8e2](https://github.com/chenhunghan/bend-kube/commit/888c8e20b90a0e2ccd69e75f50ff71c54ff7598d))

## [0.5.3](https://github.com/chenhunghan/bend-kube/compare/v0.5.2...v0.5.3) (2026-11-09)


### Bug Fixes

* leader election stops before a standby can take over, on every path ([#15](https://github.com/chenhunghan/bend-kube/issues/15)) ([5627b57](https://github.com/chenhunghan/bend-kube/commit/5627b57c110c1aea11c767b877a6cbad28f68653))

## [0.5.2](https://github.com/chenhunghan/bend-kube/compare/v0.5.1...v0.5.2) (2026-11-07)


### Bug Fixes

* a leader never sleeps past its renew deadline ([#13](https://github.com/chenhunghan/bend-kube/issues/13)) ([3f0f3db](https://github.com/chenhunghan/bend-kube/commit/3f0f3db5c862a40f8d815a547444fe7c1671637c))

## [0.5.1](https://github.com/chenhunghan/bend-kube/compare/v0.5.0...v0.5.1) (2026-11-07)


### Bug Fixes

* cap Retry-After at 1000s; drop the unused timeout mapping ([#11](https://github.com/chenhunghan/bend-kube/issues/11)) ([483175d](https://github.com/chenhunghan/bend-kube/commit/483175d2a9292824f8693c82062ddfecd2aafd4e))

## [0.5.0](https://github.com/chenhunghan/bend-kube/compare/v0.4.0...v0.5.0) (2026-11-07)


### Features

* validate election timing; read the Retry-After header ([#9](https://github.com/chenhunghan/bend-kube/issues/9)) ([75b8d4d](https://github.com/chenhunghan/bend-kube/commit/75b8d4d279a22affb052c2388826fa68776f6115))

## [0.4.0](https://github.com/chenhunghan/bend-kube/compare/v0.3.0...v0.4.0) (2026-11-07)


### Features

* controller metrics and Retry-After ([#7](https://github.com/chenhunghan/bend-kube/issues/7)) ([4891a4f](https://github.com/chenhunghan/bend-kube/commit/4891a4f7f83a87181657ce955bb37b715cdd1574))

## [0.3.0](https://github.com/chenhunghan/bend-kube/compare/v0.2.0...v0.3.0) (2026-11-07)


### ⚠ BREAKING CHANGES

* Opts gained grace, qps and burst fields, so code that builds Opts{..} directly must use Opts.default() and the with_ helpers. K.Config gained a limit field.

### Features

* production-ready controllers and operators ([#5](https://github.com/chenhunghan/bend-kube/issues/5)) ([46744f9](https://github.com/chenhunghan/bend-kube/commit/46744f95f00ad2ca7a114c5e390c37118214bdf5))

## [0.2.0](https://github.com/chenhunghan/bend-kube/compare/v0.1.2...v0.2.0) (2026-10-29)


### Features

* follow pod logs and exec into pods ([97ff804](https://github.com/chenhunghan/bend-kube/commit/97ff804976d73517b5dec8b32f9d0b9cdcb686c0))
* **stream:** fold a streaming body into a state ([77f0262](https://github.com/chenhunghan/bend-kube/commit/77f0262b4462d1efbdeda935651db99e89aa7b59))
* **time:** parse RFC 3339 stamps to epoch seconds ([ac5380b](https://github.com/chenhunghan/bend-kube/commit/ac5380b12ced8bb07b419fb5d535bb7364160c5a))


### Bug Fixes

* **yaml:** read negative, decimal and exponent numbers as numbers ([c6c3825](https://github.com/chenhunghan/bend-kube/commit/c6c3825adc52ca937c6b5efca850b2a71de1fa3b))

## [0.1.2](https://github.com/chenhunghan/bend-kube/compare/v0.1.1...v0.1.2) (2026-10-29)


### Bug Fixes

* **gen:** import a BendHub package path given as --lib as is ([4b010b5](https://github.com/chenhunghan/bend-kube/commit/4b010b5913340e5f56dda5074141d7bd6ecd5bed))

## [0.1.1](https://github.com/chenhunghan/bend-kube/compare/v0.1.0...v0.1.1) (2026-10-29)


### Bug Fixes

* publish to BendHub as bend-kube-runtime ([222c87a](https://github.com/chenhunghan/bend-kube/commit/222c87a5bed3488d146aeaa539a32194efe0f90e))

## 0.1.0 (2026-10-29)


### Features

* bend-kube, a Kubernetes client and controller runtime in Bend ([a38f023](https://github.com/chenhunghan/bend-kube/commit/a38f023f9ffec6326938c886f287e3428df6b359))
