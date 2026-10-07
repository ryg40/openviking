# Ingress gateway example

## Purpose

`nginx.conf` separates browser login from agent API authentication.
It provides no public route that bypasses both authentication boundaries.

## Prerequisites

Use a reviewed unprivileged NGINX image with `auth_request` support.
Provide shared TLS ingress that preserves the approved Host header.
Restrict gateway access to that ingress network.
Keep the API hostname private through DNS and network policy.

## Configuration groups

- The default server rejects unknown hostnames.
- The browser server sends every path through oauth2-proxy.
- The API server performs an internal native authorization subrequest first.
- `/_native_auth` calls `/api/v1/system/status` without a request body or browser cookie.
- The main API route forwards the original native credentials after successful authorization.
- Identity header removal prevents clients from supplying proxy identity claims.
- Temporary paths support a read-only proxy root filesystem.
- Disabled access logs avoid recording sensitive URLs and headers.

`auth_request` permits successful 2xx responses and rejects 401 or 403 responses.
Unexpected upstream responses fail the request rather than grant access.
The status endpoint must require native credentials in the selected deployed version.
A public status endpoint would break this design. Prove its behavior before use.

## Replacement fields

Replace `ov-browser.example.invalid` and `ov-api.example.invalid` with approved hostnames.
Keep service names aligned with `compose.ec2.yml`.
Adjust timeouts only after measuring supported client operations.
Do not change the authorization endpoint without an authenticated contract test.

## Security boundary

The browser proxy does not turn an Entra session into an OpenViking root key.
The API route accepts native `X-API-Key` or native bearer credentials.
It does not treat an arbitrary Entra access token as a native key.
Keep OpenViking in `api_key` mode with a configured root key.
Do not expose port `1933`, a second ingress route, or an application load balancer target directly.

## Deployment steps

1. Validate NGINX syntax in an isolated container network.
   Supply the example service DNS names during the check.
2. Verify the native status endpoint rejects missing credentials.
   Do not activate the API route if the endpoint allows anonymous access.
3. Install the gateway in staging.
   Use separate state and secrets.
4. Configure shared ingress for the two approved hostnames.
   Reject every other hostname before forwarding traffic.

## Validation

1. Send an API request without credentials.
   Expect 401 or 403 and no HTML login redirect.
2. Send an API request with an invalid key.
   Expect 401 or 403 and no application content.
3. Send a request with a scoped native key.
   Verify normal API behavior and tenant isolation.
4. Request `/_native_auth` directly.
   NGINX must deny the internal location.
5. Send forged identity headers without credentials.
   The request must remain unauthorized.
6. Test long-running requests and disconnects.
   Confirm the approved timeout matches client behavior.

## Costs

The gateway shares host capacity and ingress costs.
Native authorization adds one application request per API request.
Measure its effect before choosing limits.

## Rollback

Restore the previous reviewed gateway configuration and image digest during an approved window.
Keep the deny-by-default boundary during rollback.

## Known limitations

No rendered browser, live proxy, WebSocket, MCP OAuth, or enterprise login test has run.
This API design targets existing native-key agents, not new browser-based MCP OAuth clients.
Add protocol-specific routes only after separate security and compatibility tests.
