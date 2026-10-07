# Environment-isolation identity example

## Purpose

`idp-environments.yml` describes separate staging and production identity boundaries.
The proposed schema is illustrative, not an internal service contract.

## Prerequisites

Obtain the real schema and the approved identity change process.
Provide separate application registrations, assignment groups, secrets, and hostnames.
Confirm whether one Entra tenant or separate tenants meet the organization's policy.

## Configuration groups

- `environments.staging` contains only staging identifiers and callbacks.
- `environments.production` contains only production identifiers and callbacks.
- Assignment-required settings deny users without approved assignments.
- Secret references identify protected runtime values without including those values.
- `provisioning` reserves Graph operations for the internal identity service.

## Replacement fields

Replace tenant IDs, client IDs, group IDs, hostnames, and secret ARNs.
Use different client and cookie secrets for each environment.
Map approved LDAP anchors to the specified Entra group IDs.
Do not share callbacks across registrations.

## Security boundary

A staging token, cookie, secret, or GitHub environment must not authorize production access.
Separate browser assignments from native OpenViking API credentials.
Separate the application registrations and secrets of a sibling service from OpenViking where policy requires independent control.
Do not copy privileged Graph credentials into either application.

## Deployment steps

1. Review the environment map with the identity team.
   Confirm which registration owns each exact callback.
2. Translate the file into the approved schema.
   Validate the translated payload before submission.
3. Apply staging changes through the approved service.
   Keep production changes behind a separate approval.

## Validation

1. Use a staging cookie against production.
   Production must reject the session.
2. Use a staging-only user against production.
   Entra must deny access.
3. Try a staging callback with the production client ID.
   The registration must reject the callback.
4. Inspect runtime secret references.
   No environment may read the other environment's secret values.

## Costs

Separate environments add secret storage, testing, and operations costs.
Shared infrastructure can reduce host costs without merging identity boundaries.

## Rollback

Revert only the affected environment's approved registration changes.
Rotate that environment's cookie secret when session invalidation is required.

## Known limitations

The internal service schema, endpoint, assignment automation, and secret integration remain unknown.
These YAML fields do not implement environment isolation by themselves.
