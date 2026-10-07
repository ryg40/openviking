# Group-assignment identity example

## Purpose

`idp-groups.yml` describes a possible group-based browser access request.
Its schema is illustrative and must not be submitted unchanged.

## Prerequisites

Obtain the real internal service contract and an approved directory group.
Confirm Entra licensing for group-based application assignment.
Confirm how LDAP membership maps to Entra membership.

## Configuration groups

- `application` identifies the production browser application and exact callback.
- `identity_mapping` describes the directory-to-Entra group relationship.
- `groups` requests browser-login access for one reviewed group.
- `nested_group_expansion` records that inherited membership is not assumed.
- `provisioning` leaves the endpoint unresolved and excludes application-held Graph credentials.

## Replacement fields

Replace tenant, client, group object ID, LDAP group name, and hostnames.
Use the Entra group object ID rather than a display name.
Translate `permissions` into the actual service vocabulary after review.

## Security boundary

Require assignments on the enterprise application.
Do not rely on the email-domain wildcard in oauth2-proxy as an authorization rule.
Do not assume group assignment automatically grants native API access.
Provision native OpenViking tenant roles through a separate approved process.

## Deployment steps

1. Confirm the exact group membership rules.
   Record direct membership, nested membership, and synchronization delays.
2. Translate the example into the approved service schema.
   The team that runs the identity service must accept the translated request.
3. Apply the assignment to a staging registration first.
   Keep production unchanged until tests pass.

## Validation

1. Test a direct group member.
   The approved user must pass the browser boundary.
2. Test a nonmember.
   Entra must deny access.
3. Test a nested-only member.
   Record the actual result without assuming inheritance.
4. Remove a test member.
   Measure synchronization and session expiry delays.

## Costs

Confirm Entra license costs and directory synchronization effort.
The file does not provision AWS infrastructure.

## Rollback

Remove the new application assignment rather than deleting the source group.
Preserve unrelated applications that use that group.

## Known limitations

The internal schema, endpoint, and nested-group behavior remain unverified.
The example performs no production identity change.
