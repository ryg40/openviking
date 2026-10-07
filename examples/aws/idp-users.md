# Explicit-user identity example

## Purpose

`idp-users.yml` describes a possible explicit-user request for the internal identity service.
Its schema is illustrative. It is not an accepted service payload.

## Prerequisites

Obtain the actual schema, endpoint, authentication method, and approval process from the identity team.
Confirm the LDAP-to-Entra synchronization contract.
LDAP is the source directory protocol. Entra object IDs identify target identities.

## Configuration groups

- `schema_status` prevents readers from mistaking the file for a verified contract.
- `application` describes the browser URL, callback, tenant, and client registration.
- `identity_mapping` identifies the immutable source anchor and target identifier.
- `users` requests explicit browser-login assignments.
- `provisioning` reserves execution for the approved identity service.

## Replacement fields

Replace every `REPLACE_` value and the fictional LDAP distinguished name.
A distinguished name identifies an entry in an LDAP directory.
Replace example hostnames with staging hostnames.
Do not replace the unknown endpoint with a guessed Graph URL.
Translate this file only after the internal schema becomes available.

## Security boundary

Set assignment-required behavior on the Entra enterprise application.
An application registration alone does not enforce that policy.
The `browser-login` label is illustrative and grants no native OpenViking role.
Keep Graph administrator credentials out of the application and OAuth proxy.
Define how disabled or deleted LDAP users lose Entra assignments.

## Deployment steps

1. Review the identity mapping with the identity team.
   The source anchor must remain stable when the email address changes.
2. Translate the request into the actual service schema.
   Validate it against the approved schema version.
3. Submit the staging request through the approved process.
   Do not use this example as an executable payload.

## Validation

1. Test an assigned user.
   The staging browser login must succeed.
2. Test an unassigned user.
   Entra must deny access.
3. Disable the source directory user.
   Measure the actual access removal delay in staging.

## Costs

Account for identity licensing and synchronization operations.
This file creates no cloud resource.

## Rollback

Remove only the assignments created by the approved change.
Retain an audit record and invalidate sessions according to the identity policy.

## Known limitations

The endpoint, schema, permission vocabulary, LDAP anchor, and synchronization behavior remain unknown.
The example submits no request.
