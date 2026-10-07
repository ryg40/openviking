# Optional EC2 host template

## Purpose

`host.cfn.yml` creates an optional private EC2 host inside existing network infrastructure.
Prefer existing capacity when measurements show enough headroom.
The template does not install Docker or deploy OpenViking.

## Prerequisites

Provide a patched x86_64 Linux AMI with a working SSM Agent.
An AMI is an EC2 machine image. SSM provides approved remote management.
Provide an existing private subnet, security group, IAM instance profile, and KMS key.
Provide shared egress or approved private endpoints for SSM, registry, secrets, logs, and model access.

## Configuration groups

- Parameters identify existing network, identity, image, and encryption resources.
- `Host` creates one instance without a public address or SSH key.
- The instance profile supplies approved host-side permissions.
- Metadata settings require tokens and reduce accidental container access.
- The encrypted root disk holds only replaceable host software.
- Outputs identify the instance for the separate storage template.

## Replacement fields

Replace all parameters with reviewed regional resources.
`t3.medium` is a trial default, not a production sizing decision.
Verify CPU architecture, root device mapping, CPU credit charges, and memory headroom for the selected AMI.
The application state belongs on the separate volume, not the disposable root disk.

## Security boundary

The security group must deny public SSH and raw application port access.
Allow ingress only from approved shared ingress and administration paths.
Use narrowly scoped runtime secret permissions on the host role.
Block application access to instance metadata with host network policy.
Do not put secret values in CloudFormation parameters or UserData.

## Deployment steps

1. Validate the template with `cfn-lint host.cfn.yml`.
   Resolve syntax and resource-property errors.
2. Review a CloudFormation change set.
   Confirm that no dedicated ALB, NAT gateway, or public address appears.
3. Execute the approved change set.
   The instance begins incurring charges.
4. Apply the approved host configuration through SSM.
   Install the container runtime and network policy without exposing credentials.
5. Attach separate application storage through the storage template.
   Keep each application's data and backup policy separate.

## Validation

1. Inspect public address and security group settings.
   The host must have no unauthenticated public route.
2. Test approved SSM access.
   No inbound SSH rule should be necessary.
3. Test container metadata access.
   The application container must not obtain the host role credentials.
4. Measure workload peaks in staging.
   Confirm the host can support every application and its own operating system.

## Costs

Estimate 730 host hours per month for continuous use.
Add root and state storage, CPU credits when applicable, backups, model calls, and shared network charges.
Check current regional prices before approval.

## Rollback

Move traffic only after a replacement host passes authenticated acceptance tests.
Preserve and safely detach state before deleting a host stack.
The root disk is disposable and deletes with the instance.

## Known limitations

No host bootstrap, SSM policy, backup plan, Docker installation, or production workload test is included.
The template trusts existing network and IAM resources; it does not validate their policies.
