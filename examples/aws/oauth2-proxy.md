# Browser OAuth proxy example

## Purpose

`oauth2-proxy.cfg` places Entra login before browser access to OpenViking.
It does not replace native application authorization.

## Prerequisites

Provide a reviewed oauth2-proxy image and an Entra application registration.
Register the exact HTTPS callback URL as a web callback.
Require assignments on the corresponding enterprise application.
Assign only approved users or groups.
Confirm the chosen proxy version supports every setting in this file.

## Configuration groups

- The provider uses one tenant-specific OpenID Connect issuer.
- The client ID identifies the browser application registration.
- The callback returns the login response to `/oauth2/callback`.
- The upstream points to the private OpenViking service.
- The email wildcard relies on Entra assignment-required enforcement, not domain authorization.
- Secure host-only cookies isolate browser sessions by hostname.
- Disabled token forwarding prevents Entra tokens from replacing native API credentials.
- Runtime environment variables supply secret values.

OpenID Connect adds user identity to OAuth.
Use separate clients, cookie secrets, and cookie names for each environment.
Do not add bypass paths or enable JWT bearer bypass for this browser boundary.

## Replacement fields

Replace the tenant ID, client ID, browser hostname, and environment-specific cookie name.
Supply `OAUTH2_PROXY_CLIENT_SECRET` and `OAUTH2_PROXY_COOKIE_SECRET` through the protected runtime file.
Match the registered callback exactly, including its path and HTTPS scheme.
Do not use the `common` issuer for this single-tenant design.

## Security boundary

A browser session allows access to the application boundary only.
Native OpenViking API authorization still applies inside that boundary.
Studio may require a separate native user key.
Test how the selected proxy version preserves `X-API-Key` for browser API calls.
Never inject the root key into shared proxy headers or browser storage.
Privileged Microsoft Graph credentials belong to the approved identity service, not these containers.

## Deployment steps

1. Obtain an approved staging application registration.
   The identity team must confirm assignment-required behavior.
2. Register the exact callback URL.
   Unregistered callbacks must fail.
3. Inject the runtime secrets.
   Check permissions without printing values.
4. Start the proxy in an isolated staging environment.
   Do not connect it to live data.

## Validation

1. Sign in as an assigned test user.
   The browser must reach OpenViking through the proxy.
2. Sign in as an unassigned test user.
   Entra must deny access.
3. Sign in through a different tenant.
   The configured issuer must reject the identity.
4. Test logout and assignment removal.
   Record actual session expiry and revocation delay.
5. Test native authorization after browser login.
   The user must not gain another tenant's data or administrator access.

## Costs

Budget for proxy memory, shared ingress, and any required Entra license.
The identity team must confirm group assignment licensing.

## Rollback

Restore the previous reviewed proxy configuration and image digest.
Rotate the cookie secret if session invalidation is required.
Keep native authorization enabled throughout rollback.

## Known limitations

No Entra login or native browser-header compatibility test has run.
A valid session can outlive an assignment change until the relevant expiry or refresh boundary.
Do not claim immediate revocation without a measured test.
