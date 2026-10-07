# Inactive image-build workflow

## Purpose

`build.workflow.yml` shows the required build and publication boundaries.
It stays under `examples/` and cannot run as a GitHub workflow there.
An explicit failing step also blocks accidental activation.

## Prerequisites

Provide an approved GitHub repository or mirror of this repository.
A repository on the private Git server alone does not run GitHub Actions.
Provide a protected `openviking-build` environment and a private ECR repository.
ECR is the AWS container registry.
Provide an AWS GitHub OIDC trust provider and a narrowly scoped build role.
OIDC exchanges short-lived job identity for AWS credentials without storing AWS access keys.

## Configuration groups

- Manual dispatch avoids automatic execution on untrusted pull requests.
- Repository permissions allow only source reads.
- The build job can request an OIDC token inside its protected environment.
- Checkout disables persisted Git credentials.
- AWS credential configuration assumes only the build role.
- The required enterprise build integration produces a release record.
- The validation step checks an immutable digest and explicit scan results.
- Artifact upload retains only the release record, not secrets or application data.

## Replacement fields

Replace every action reference with a reviewed full commit SHA.
Set `AWS_BUILD_ROLE_ARN`, `AWS_REGION`, and `ECR_REPOSITORY` as approved environment variables.
Implement `enterprise/build-scan-publish` before removing the failing step.
The integration must build a reviewed source commit with locked dependencies and pinned base image digests.
It must exclude `.env`, application data, local credentials, and deployment secret files from the build context.

The integration must scan the image and software dependencies before publication.
It must enforce the organization's severity and exception policy.
It must generate and verify provenance, then publish to the approved registry.
Provenance identifies the source and build process behind an artifact.
The release record must bind the source commit, image digest, scan evidence, and provenance evidence.
Boolean fields alone are not proof of those checks.

## Security boundary

Restrict AWS trust to `aud=sts.amazonaws.com` and the exact GitHub environment subject.
A subject has the form `repo:ORG/REPO:environment:openviking-build`.
Restrict branches through the protected GitHub environment.
Scope ECR writes to the one approved repository.
The build role must not read runtime secrets or deploy applications.
The deployment system must independently verify the release record and registry digest.

## Deployment steps

1. Review the enterprise build integration.
   Confirm locked dependencies, scanning, and provenance checks.
2. Configure protected environment approvals and AWS trust.
   Reject tokens from other repositories and environments.
3. Pin every referenced action.
   Do not use mutable tags for production activation.
4. Move a reviewed copy into `.github/workflows/` after separate approval.
   Remove the failing step only in that approved copy.

## Validation

1. Run `actionlint` against the reviewed copy.
   Resolve workflow and shell findings.
2. Test a denied repository identity.
   AWS must refuse role assumption.
3. Test an image that violates the scan policy.
   The integration must refuse publication.
4. Inspect the release record.
   It must contain a digest and verifiable evidence without secret values.

## Costs

Budget for GitHub runners, native image compilation, registry storage, scanning, and network transfer.
The upstream Dockerfile builds Rust, C++, Python, and Studio components.
Do not assume a small runtime host can build the image efficiently.

## Rollback

Keep the previous approved image digest and release record.
Disabling the workflow stops future builds but does not change running services.

## Known limitations

The enterprise build script, reviewed action hashes, OIDC role, and GitHub mirror are not supplied.
Not verified: workflow execution, image build or publication through this example.
