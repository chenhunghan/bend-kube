# Changelog

## [0.11.0](https://github.com/chenhunghan/bend-kube/compare/v0.10.0...v0.11.0) (2026-11-24)


### Features

* hash what Unz.file writes (Unz.file_sha256) ([ef97dcd](https://github.com/chenhunghan/bend-kube/commit/ef97dcd740a66bca489d8b52d9d65ec2ab835471))
* Tls.available, and OpenSSL loads that retry after a failure ([b17b1b4](https://github.com/chenhunghan/bend-kube/commit/b17b1b415ad4690efc56793bb2c7ddf8099e5b7c))

## [0.10.0](https://github.com/chenhunghan/bend-kube/compare/v0.9.0...v0.10.0) (2026-11-17)


### Features

* decompress straight into a file (Unz.sink, Unz.write, Unz.file) ([b9bdaba](https://github.com/chenhunghan/bend-kube/commit/b9bdaba69088d47e8f3f02d60fc27194426c1883))

## [0.9.0](https://github.com/chenhunghan/bend-kube/compare/v0.8.1...v0.9.0) (2026-11-17)


### Features

* a streaming gzip decoder in pure Bend (src/gzip.bend) ([a7b162a](https://github.com/chenhunghan/bend-kube/commit/a7b162afd7dd4f611f129767353186da80b236be))
* gRPC servers and clients (src/grpc.bend, src/grpcio.bend) ([1319853](https://github.com/chenhunghan/bend-kube/commit/1319853c068577b162be726539aa582bef6b9abd))
* gzip and zstd decompression through zlib and libzstd (src/unz.bend) ([3e18bba](https://github.com/chenhunghan/bend-kube/commit/3e18bbaf58cb9210b59b82796cca308bf2e063f4))
* HPACK header compression (src/hpack.bend) ([8f37216](https://github.com/chenhunghan/bend-kube/commit/8f3721678a07d1826d7b02410d847068bb4ab1d8))
* HTTP/2 over sockets (src/h2.bend, src/h2io.bend) ([798ba98](https://github.com/chenhunghan/bend-kube/commit/798ba983e6bd466a124d06a90413e39054eb5aaa))
* protobuf wire format (src/pb.bend) ([af29f5c](https://github.com/chenhunghan/bend-kube/commit/af29f5c0527b5c419a03bb66e71e8da5d6120a5b))
* Unix-socket listen and connect (Sys.unix_listen, Sys.unix_connect) ([7d9b6e0](https://github.com/chenhunghan/bend-kube/commit/7d9b6e064be8ac48b14300a182b93cd2d37ae1ec))


### Performance Improvements

* HTTP/2 bodies in linear time ([abfd2af](https://github.com/chenhunghan/bend-kube/commit/abfd2afd7501fe1bb40bf2ffe10ae154908ada7b))

## [0.8.1](https://github.com/chenhunghan/bend-kube/compare/v0.8.0...v0.8.1) (2026-11-10)


### Bug Fixes

* harden the webhook server and TLS from the production review ([#27](https://github.com/chenhunghan/bend-kube/issues/27)) ([2ac6016](https://github.com/chenhunghan/bend-kube/commit/2ac601691280ecfcfddd9b9b3c36defed52d81db))
* runtime and client fixes from the production review ([#29](https://github.com/chenhunghan/bend-kube/issues/29)) ([a78f2af](https://github.com/chenhunghan/bend-kube/commit/a78f2afe0fea6a222cd720ebf7e0bcdc683ba0ac))

## [0.8.0](https://github.com/chenhunghan/bend-kube/compare/v0.7.0...v0.8.0) (2026-11-10)


### Features

* admission and conversion webhooks over a TLS server ([#25](https://github.com/chenhunghan/bend-kube/issues/25)) ([fede360](https://github.com/chenhunghan/bend-kube/commit/fede360156df9b339417612c74bfef6266bada51))

## [0.7.0](https://github.com/chenhunghan/bend-kube/compare/v0.6.0...v0.7.0) (2026-11-10)


### Features

* a watchdog keeps reconcile timeouts, not a sleeper per reconcile ([f719ce2](https://github.com/chenhunghan/bend-kube/commit/f719ce23768bea6632aa8cbbeaf8b79743b80390))
* one pool per cluster, the server in watch logs, Client.replace_retry ([8219fd2](https://github.com/chenhunghan/bend-kube/commit/8219fd2a29dfde4831614b2783a0a41d170712b5))
* relations mapped by code (X.RMap, Kube.control_mapped) ([1a2786e](https://github.com/chenhunghan/bend-kube/commit/1a2786eddcb3d6e6ac15a9eef19ac5e85b955bdb))

## [0.6.0](https://github.com/chenhunghan/bend-kube/compare/v0.5.5...v0.6.0) (2026-11-10)


### Features

* watches on other clusters, filters on related watches, a manager-wide reconcile timeout ([#22](https://github.com/chenhunghan/bend-kube/issues/22)) ([f704b24](https://github.com/chenhunghan/bend-kube/commit/f704b2474f4b9cc89233d51b05ff340abb23babf))

## [0.5.5](https://github.com/chenhunghan/bend-kube/compare/v0.5.4...v0.5.5) (2026-11-09)


### Bug Fixes

* fence every write of request bytes, through a keeper that always answers ([#19](https://github.com/chenhunghan/bend-kube/issues/19)) ([5be605f](https://github.com/chenhunghan/bend-kube/commit/5be605f8aeaa41a4170203821427599c33a96290))

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
