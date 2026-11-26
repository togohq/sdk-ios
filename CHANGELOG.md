# Changelog

Every notable change to the Togo AI iOS SDK. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package follows
[Semantic Versioning](https://semver.org/): each version is a tag of this repository, which Swift
Package Manager resolves.

## [1.2.0] - 2026-11-26

Version 1.2.0 introduces experiment management with offline capabilities and improves session
handling.

### Added

- **`getExperiment()`** and **`cachedExperiment()`** provide stored answers for experiments, working
  offline and supporting first screen decisions.

### Changed

- The SDK now handles experiment exposure and stamps more effectively, ensuring consistent session
  behavior.
- Documentation now includes details on `getExperiment`, `cachedExperiment`, and related
  configurations.

### Fixed

- A finished experiment's stamp now remains ended for the entire session, preventing incorrect
  re-stamping.
- **`reset()`** now retains the record of entered experiments even on a locked device, ensuring
  accurate tracking.
- **`setup()`** no longer mints IDs when there are no experiments to preload, avoiding unnecessary
  ID creation.

## [1.1.0] - 2026-11-26

This release introduces wrapper SDK naming and fixes UTF-16 version length validation.

### Added

- **`TogoConfig.wrapper`** allows a wrapper SDK to set its name and version on every event, ensuring
  accurate identification.

### Fixed

- Version length is now correctly validated in UTF-16 code units, preventing batch rejections for
  certain strings.

## [1.0.0] - 2026-11-24

The first release of the Togo iOS SDK, providing event tracking and user identification
capabilities.

### Added

- **`Togo.setup()`** initializes the SDK with configuration options, setting up event tracking and
  user identification.
- **`Togo.track()`** allows tracking of custom events with properties, supporting up to 256
  properties per event.
- **`Togo.identify()`** sets a unique user identifier, associating events with a specific user.
- **`Togo.setPersonProperties()`** updates user profile properties, including typed fields for email
  and name.
- **`Togo.setConsent()`** manages user consent states, affecting data collection and storage.
- **`Togo.getConsent()`** retrieves the current consent state of the user.
- **`Togo.getAnonymousId()`** returns the anonymous identifier used for tracking before user
  identification.
- **`Togo.getDeviceId()`** provides the device identifier used in event tracking.
- **`Togo.getSessionId()`** retrieves the current session identifier, if sessions are enabled.
- **`Togo.flush()`** sends all queued events to the server immediately.
- The SDK supports offline event queuing, persisting events until they can be sent.
- Events are batched and sent with a 256 KiB limit per event and an 8 MiB queue limit.
- The SDK includes a privacy manifest declaring collected data types and purposes.
- A minimal example app demonstrates SDK setup and event tracking.
- The SDK follows semantic versioning from this release onwards.

### Changed

- **Semantic versioning.** The public API is now stable: from this version on, a breaking change
  ships only in a new major version.
