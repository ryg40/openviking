# EC2 Compose example

## Purpose

`compose.ec2.yml` separates the application, browser authentication proxy, and ingress gateway.
It does not replace the live Compose file.

## Prerequisites

Use an approved Docker host with the Compose plugin and an encrypted state filesystem.
Provide a shared TLS ingress service on the `approved-ingress` network.
TLS encrypts traffic between the client and ingress.
Prepare secret files under `/run/openviking` through an approved host-side secret retrieval service.
Keep those files outside Git, images, build contexts, command arguments, and logs.

## Configuration groups

- `openviking` keeps native `api_key` authorization and owns the state directory.
- `oauth2-proxy` provides the browser login boundary without granting native administrator access.
- `gateway` separates browser traffic from native API traffic.
- `backend` limits network membership to these containers.
- `ingress` connects only the gateway to the existing ingress system.
- Resource limits constrain application use but do not reserve enough host capacity by themselves.
- Dropped capabilities and `no-new-privileges` reduce process privileges.
- Read-only proxy filesystems keep temporary writes under `/tmp`.

The application filesystem remains writable because image compatibility is not yet proven.
The example does not mount a Docker socket or publish the raw application port.

## Replacement fields

Supply `OPENVIKING_IMAGE`, `OAUTH2_PROXY_IMAGE`, and `NGINX_IMAGE` as tested `repository@sha256:...` references.
Compose checks only that these variables exist. The release process must reject mutable tags.
Replace the browser hostname in both Compose and the proxy files.
Prepare `/srv/openviking/state/ov.conf` with the tested version's model and storage configuration.
Set `server.auth_mode` to `api_key` and provide the required root key.
Do not commit the actual configuration because it can contain credentials.

`app.env` supplies `OPENVIKING_ROOT_API_KEY` at runtime.
`oauth.env` supplies `OAUTH2_PROXY_CLIENT_SECRET` and `OAUTH2_PROXY_COOKIE_SECRET`.
Generate the cookie secret with the chosen proxy version's documented length and encoding.
Use separate files and secrets for staging and production.

## Security boundary

The host retrieves only approved secret ARNs with its own IAM role.
IAM is AWS access control. An ARN identifies an AWS resource.
Protect runtime files with restrictive directory permissions and mode `0600`.
Docker administrators can inspect container environment variables.
This design therefore trusts host administrators and does not claim protection from them.
Block application containers from instance metadata through host network rules.
Do not rely only on the metadata hop limit.

The application UID is `10001`. The proxy UIDs depend on the reviewed images.
Prepare state ownership on a new staging directory only.
Do not change ownership of live data to test this example.

## Deployment steps

1. Mount the approved encrypted state volume.
   Confirm the volume ID before any format operation.
2. Prepare the runtime secret files.
   Check file permissions without printing their contents.
3. Validate the configuration with `docker compose -f compose.ec2.yml config --quiet`.
   The command must succeed without exposing interpolated secrets.
4. Start an isolated staging project during an approved window.
   Do not reuse live ports, networks, or data paths.
5. Connect the approved ingress routes.
   Send only the two reviewed hostnames to gateway port `8080`.

## Validation

1. Run the authentication tests in [PLAN.md](PLAN.md).
   All denied requests must fail without application content.
2. Test initialization and ingestion as the non-root UID.
   No required path may fail with a permission error.
3. Test a container replacement against staging state.
   Authenticated retrieval must retain the expected data.
4. Inspect container mounts and published ports.
   No Docker socket or raw application port may appear.

## Costs

Budget for the host, encrypted EBS, backups, registry, shared ingress, and model access.
The application limits are trial values, not a capacity recommendation.

## Rollback

Restore the previous image digest and its compatible backup in a separate directory.
Follow the rollback sequence in [PLAN.md](PLAN.md).

## Known limitations

Non-root compatibility, proxy behavior, streaming behavior, and enterprise secret delivery remain untested.
The example omits deployment automation intentionally.

Warning: Formatting an existing volume can destroy data.
