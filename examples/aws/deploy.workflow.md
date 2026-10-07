# Inactive deployment workflow

## Purpose

`deploy.workflow.yml` shows a protected deployment transaction without implementing enterprise integrations.
The file remains inactive under `examples/` and contains an explicit failing step.

## Prerequisites

Provide the approved GitHub mirror, protected production environment, and AWS OIDC trust.
Provide an approved host-specific SSM document and a tagged EC2 target.
Provide a consistent backup process and a tested rollback process.
Provide a release record with verified scanning and provenance evidence.

## Configuration groups

- Manual input selects an immutable image digest.
- Concurrency prevents overlapping production deployments without cancelling an active transaction.
- The environment requires production approval.
- The validation step passes input through an environment variable rather than shell interpolation.
- OIDC role assumption supplies short-lived deployment authority.
- The enterprise transaction owns backup, deployment, acceptance, and rollback.

## Replacement fields

Pin every action to a reviewed full commit SHA.
Set `AWS_DEPLOY_ROLE_ARN` and `AWS_REGION` in the protected environment.
Implement `enterprise/deploy-openviking-transaction` before activation.
The script must select a fixed approved registry repository, not an input-supplied repository.
It must reject unknown digests, failed scans, and missing provenance.

## Security boundary

Restrict OIDC trust to `aud=sts.amazonaws.com` and the exact production environment subject.
The subject has the form `repo:ORG/REPO:environment:openviking-production`.
Restrict deployment branches and require human approval through that environment.
Scope the deployment role to one approved SSM document and tagged target hosts.
Do not permit arbitrary shell documents or application secret reads.
The host role retrieves runtime secrets directly from approved secret ARNs.
Keep values out of Actions logs, SSM parameters, command output, and artifacts.

## Transaction requirements

1. Verify the release evidence against the registry digest.
   Refuse unapproved or mutable artifacts.
2. Acquire the host's deployment lock.
   Refuse concurrent changes outside this workflow too.
3. Pause writes through an approved maintenance procedure.
   Confirm a consistent backup boundary before snapshots.
4. Verify the new backup and previous rollback record.
   Stop if either required gate fails.
5. Start the approved image digest with runtime secrets.
   Keep the raw application private.
6. Run authenticated acceptance tests.
   Check browser denial, API denial, tenant isolation, and representative retrieval.
7. Restore compatible state and the previous digest if acceptance fails.
   Return a failure result even when rollback succeeds.

The enterprise integration must also handle runner loss, SSM timeout, and partial host failure.
The host transaction must not depend on the runner remaining connected.
No supplied script currently implements these requirements.

## Deployment steps

1. Implement and test the transaction in staging.
   Include backup failure and interrupted deployment tests.
2. Configure production approval and narrowly scoped role trust.
   Reject staging and unrelated repository identities.
3. Review a copy under `.github/workflows/`.
   Remove the failing step only after separate activation approval.

## Validation

1. Run `actionlint` on the reviewed workflow.
   Resolve syntax and shell findings.
2. Submit an invalid digest in staging.
   The workflow must reject it before AWS commands run.
3. Force a backup failure in staging.
   The host must keep the existing application version.
4. Force an acceptance failure in staging.
   The transaction must restore the compatible previous version and data.

## Costs

Budget for runner time, snapshot storage, restoration tests, logs, and temporary staging capacity.
The example does not create dedicated ingress or egress infrastructure.

## Rollback

Use the transaction's verified previous digest and compatible snapshot.
Do not roll back only the image after an incompatible data migration.
Keep an approved host-side recovery procedure for complete CI failure.

## Known limitations

The SSM document, transaction script, IAM policies, backup service, and acceptance tests remain enterprise prerequisites.
The example stays inactive and performs no deployment.
