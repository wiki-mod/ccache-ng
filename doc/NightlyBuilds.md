# ccache-ng nightly builds

This repository publishes ccache-ng nightly and release outputs from the
current checkout through one orchestrating GitHub Actions workflow.

## Published outputs

- `ghcr.io/<owner>/ccache-ng:latest`
- `ghcr.io/<owner>/ccache-ng:nightly`
- `ghcr.io/<owner>/ccache-ng:<full sha>`
- nightly and release archives on the repository release page

## Behavior

- The nightly workflow first compares the current build identity with the last
  accepted nightly metadata.
- If nothing relevant changed, the run stops in `noop`.
- A successful run updates the container tags only after all required build
  jobs finished successfully.
- Failed nightly runs open or append to one issue, and the next successful run
  closes it again.

## Manual runs

The workflow supports manual runs for:

- `nightly`
- `release`
- `verify`
- `gc`

Manual runs can also select `amd64`, `arm64`, or `all`, plus publish and debug
controls.

Single-architecture manual runs build only that architecture. They do not move
`latest`, `nightly`, or release tags.
