# kitchen-noderings

[![CI](https://github.com/noderings/kitchen-noderings/actions/workflows/ci.yml/badge.svg)](https://github.com/noderings/kitchen-noderings/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/kitchen-noderings.svg)](https://rubygems.org/gems/kitchen-noderings)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

A [Test Kitchen](https://kitchen.ci/) driver that runs your test instances on
[NodeRings](https://noderings.com) virtual machines.

New to it? The step-by-step guide [How to use Chef on a NodeRings VPS: cookbook, knife and Test Kitchen](https://noderings.com/blog/chef-vps) walks through a first run.

For each instance the driver orders the cheapest matching offer from the NodeRings
marketplace, installs a temporary SSH key, waits until SSH answers, and on
`kitchen destroy` deletes both the server and the key. Hourly (usage) plans stop
billing as soon as the server is deleted.

## Requirements

* Ruby 3.1 or later
* Test Kitchen 3 or 4 (Chef Workstation and Cinc Workstation both ship it)
* A NodeRings service account token. Create one in the NodeRings console under
  **Organization → Access Control → Service accounts**.
* A payment method or credit on the organization, because ordering a server is billed.

## Installation

```shell
chef gem install kitchen-noderings     # Chef Workstation
cinc gem install kitchen-noderings     # Cinc Workstation
gem install kitchen-noderings          # plain Ruby with Bundler
```

## Usage

```yaml
# kitchen.yml
driver:
  name: noderings
  plan: SC-GC-1C-1G-20
  country: United States
  city: Ashburn

provisioner:
  name: chef_infra
  product_name: cinc

platforms:
  - name: ubuntu-24.04
  - name: debian-13
  - name: rockylinux-9

suites:
  - name: default
    run_list:
      - recipe[my_cookbook::default]
```

```shell
export NODERINGS_TOKEN=...   # the service account token
kitchen test
```

To see which plans are sold where, use the NodeRings console marketplace, or
`knife noderings plan list --country "United States" --city Ashburn` from
[knife-noderings](https://github.com/noderings/knife-noderings).

## Configuration

| Option | Default | Description |
| --- | --- | --- |
| `noderings_api_token` | `NODERINGS_TOKEN` environment variable | API token. Prefer the environment variable to keep it out of `kitchen.yml`. |
| `noderings_api_url` | `https://api.noderings.com` | API endpoint (`NODERINGS_API_URL`). |
| `noderings_organization_id` | none | Organization to act in, for tokens that can reach more than one (`NODERINGS_ORGANIZATION_ID`). |
| `plan` | none | Plan code to order, such as `SC-GC-1C-1G-20`. Required with `country` and `city`. |
| `country` | none | Country of the offer, such as `United States`. |
| `city` | none | City of the offer, such as `Ashburn`. |
| `billing_type` | `usage` | `usage` (hourly), `subscription` (monthly) or `free`. |
| `sort` | `price` | Order the cheapest matching offer, or the best rated with `rating`. |
| `provider_id` | none | Only consider offers from this provider. |
| `plan_id`, `region_id` | none | An exact plan and region, instead of `plan`, `country` and `city`. |
| `distro` | from the platform name | NodeRings distro, such as `ubuntu_24_04`. |
| `server_name` | `kitchen-<instance>-<random>` | Hostname of the server (at most 63 characters). |
| `noderings_ssh_keys` | `[]` | Names or IDs of existing NodeRings SSH keys to install. Leave empty to use a temporary key. |
| `firewall_ruleset` | none | Name or ID of a firewall ruleset to attach. It must allow SSH from where Kitchen runs. |
| `tags` | `["test-kitchen"]` | Tags on the server. |
| `username` | `root` | SSH user. |
| `port` | `22` | SSH port. |
| `server_wait_timeout` | `900` | Seconds to wait for the server to be provisioned. |

### Platforms

The platform name becomes the NodeRings distro: `ubuntu-24.04` is ordered as
`ubuntu_24_04` and `debian-13` as `debian_13`. Names that differ are mapped:

| Platform | Distro |
| --- | --- |
| `rockylinux-9`, `rockylinux-10` | `rocky_9`, `rocky_10` |
| `centos-stream-9`, `centos-stream-10` | `centos_9`, `centos_10` |

Set `distro` on a platform to choose any other image. The images on offer are
Ubuntu 22.04, 24.04 and 26.04, Debian 12 and 13, Fedora 43 and 44, CentOS Stream
9 and 10, AlmaLinux 9 and 10, and Rocky Linux 9 and 10.

### SSH keys

By default the driver uses the transport's `ssh_key`, or generates an RSA key in
`.kitchen/`, uploads its public half to NodeRings as `kitchen-<server name>`,
and deletes both on `kitchen destroy`. To use keys already stored in NodeRings,
list them in `noderings_ssh_keys` and point the transport's `ssh_key` at the
matching private key.

## How it works

1. `kitchen create` picks an offer: the plan code in the city, filtered by
   billing type and provider, sorted by price or rating.
2. It orders the server with an idempotency key, so a lost response never orders
   twice, and records the server ID in the instance state at once. A retried
   create does nothing when the state already names a server.
3. It waits until the server is provisioned and has an address, attaches the
   firewall ruleset if one is set, and waits for SSH.
4. `kitchen destroy` deletes the server and the temporary key, and tolerates a
   server that is already gone.

`kitchen doctor` checks the token against the API and the offer settings before
anything is ordered.

## Development

```shell
bundle install
bundle exec rake          # unit tests and Chefstyle
```

The unit tests run against an in-memory NodeRings API, so they need no token.
The driver talks to the API with the Ruby standard library only. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

Copyright NodeRings. Licensed under the [Apache License, Version 2.0](LICENSE).
