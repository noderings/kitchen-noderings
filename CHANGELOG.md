# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-25

### Added

- The `noderings` Test Kitchen driver: orders the cheapest matching NodeRings
  marketplace offer (or the best rated, or an exact plan and region), waits for
  the server's address and for SSH, and deletes the server afterwards.
- A temporary SSH key per instance, generated or taken from the transport, and
  deleted on `kitchen destroy`. Existing NodeRings keys can be used instead.
- Platform names map to NodeRings distros (`ubuntu-24.04`, `debian-13`,
  `rockylinux-9`, `centos-stream-10` and others).
- Optional firewall ruleset, tags, billing type and provider selection.
- `kitchen doctor` checks the API token and offer settings before anything is billed.
