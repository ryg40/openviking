# AWS deployment examples

These examples are inactive design material. They do not change the live service.
The internal `idp.yml` schema and Graph service endpoint are unknown.
No example claims compatibility with that service.

## Start here

- [Implementation plan](PLAN.md): EC2 first, with Fargate and ECS comparisons.
- [EC2 Compose](compose.ec2.md): containers, storage, limits, and secret files.
- [Ingress configuration](nginx.md): separate browser and API authentication.
- [OAuth proxy](oauth2-proxy.md): tenant-specific login through Microsoft Entra ID, an OIDC identity provider.
- [Explicit users](idp-users.md): illustrative user assignments.
- [Group assignments](idp-groups.md): illustrative group access.
- [Environment isolation](idp-environments.md): separate staging and production.
- [Existing-host storage](storage.cfn.md): encrypted EBS storage.
- [Optional EC2 host](host.cfn.md): a new host within existing network capacity.
- [Build workflow](build.workflow.md): inactive GitHub Actions mockup.
- [Deploy workflow](deploy.workflow.md): inactive release mockup.

Each configuration has its own explainer. Read it before changing the configuration.
Do not move workflows into `.github/workflows/` without a separate security review.

## Evidence boundary

The examples assume the default state layout of this fork (see `docs/host-configuration.md`).
The default configuration uses local AGFS storage and a SQLite queue.
AGFS is the file storage layer of OpenViking.
The vector database also uses its local backend.
The workspace is `/app/.openviking/data` inside the container.
The host stores the complete application directory under `data/` of the checkout.

The examples give no measured sizing value. Measure memory and disk use with representative workloads.
The image runs as root by default.
Non-root operation in these examples requires a separate compatibility test.

## Validation boundary

Static checks can prove syntax, but they cannot prove enterprise integration.
No AWS deployment, Entra login, restored backup, or proxy end-to-end test has run for these examples.
No formal STE certification is claimed.
