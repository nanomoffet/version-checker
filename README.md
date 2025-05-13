# Version Checker Script

This script checks deployed service versions against their corresponding GitHub releases. It can filter and display version comparison results for services based on configuration and optionally using an interactive mode.

## Prerequisites

Make sure you have the following dependencies installed:

- `bash` (Version 4.3 or later)
- `yq`
- `jq`
- `curl`
- `gh` (GitHub CLI, authenticated)
- `gum`

## Usage

```sh
./version-checker.sh [OPTIONS]
```

### Options

- `-f <config_file>`: Specify a custom YAML configuration file (default is `config.yaml`).
- `-c, --config`: Enter interactive configuration mode using `gum` to select query filters and GitHub versions for comparison.
- `-v, --verbose`: Enable verbose mode to display the service URLs that are being queried.
- `-r <region_mode>`: Set the region selection mode. Overrides interactive or config-defined region filters. Valid options are `'off'`, `'primary'`, `'secondary'`, and `'all'`.
- `-h, --help`: Display the help message and exit.

### Region Modes

- `off`: Do not filter by region. Query only one instance per service/tenant/environment combination.
- `primary`: Select the first matching instance for each service/tenant/environment combination.
- `secondary`: Select the second matching instance for each service/tenant/environment combination.
- `all`: Include all matching targets regardless of region.

## Configuration

The script is designed to be configured via a YAML file (default named `config.yaml`). This file should define the default tenants, environments, regions, and services to query, along with the mappings of services to their respective GitHub repositories.

### Global Configuration Parameters

- `default_curl_timeout_seconds`: Specifies the default timeout for curl requests.
- `default_version_jq_query`: JQ query to extract the version from the service's response.
- `service_url_template`: Template URL for querying the service version.
- `github_release_cache_ttl_seconds`: Time-to-live in seconds for the cached GitHub releases.

### Example Configuration File

```yaml
global:
  default_curl_timeout_seconds: 10
  default_version_jq_query: '.version'
  service_url_template: 'https://{service_url_param}-{region_url_param}-service.com/{effective_tenant}/{effective_env}/version'
  github_release_cache_ttl_seconds: 3600

defaults:
  tenants: [all]
  environments: [all]
  regions: [all]
  services: [all]

services_repo_map:
  service1:
    display_name: Service One
    repo: org/service1-repo
```
