# AWS implementation plan

## Purpose

Use existing EC2 capacity when it meets measured requirements.
Keep model inference outside this host unless a separate GPU plan proves capacity.
Do not use Lightsail.

## Prerequisites

- An approved AWS account, region, and budget.
- An existing VPC, private subnet, shared ingress, and controlled outbound access.
- A protected image registry and a tested image digest.
- An approved application registration in an OIDC identity provider and an internal identity service contract.
  These examples use Microsoft Entra ID as that identity provider.
- Model endpoints with approved data handling, network routes, and credentials.
- A tested backup destination and an agreed recovery time.

A VPC is an isolated AWS network.
EBS provides block storage for EC2.
ECS schedules containers. Fargate runs ECS tasks without a self-managed host.

## Options and cost assumptions

| Option | Persistent storage | Cost model | Decision |
| --- | --- | --- | --- |
| Existing EC2 with Docker | Separate encrypted gp3 EBS volume | Added storage, snapshots, traffic, and consumed host capacity | Main option |
| New EC2 with Docker | Separate encrypted gp3 EBS volume | Host hours plus storage and shared network charges | Use only after capacity review |
| Fargate | External supported state services or a proven storage design | Continuous task CPU and memory plus storage and network charges | Secondary research option |
| ECS on self-managed EC2 | Host-bound EBS with controlled placement | Existing host capacity plus ECS operating effort | Optional third option |

ECS Managed Instances is outside this plan.
No option needs a dedicated ALB or NAT gateway for each application.
ALB means Application Load Balancer. NAT permits outbound access from a private network.
Reuse approved shared services. Do not create an uncontrolled public host to avoid NAT costs.
Private endpoints also have charges. Compare them with existing shared egress.

Estimate monthly host cost as `730 × hourly rate`.
Add EBS capacity, provisioned performance, snapshots, registry storage, logs, model usage, and data transfer.
Use current regional prices before approval. This plan contains no current price quote.
Existing capacity has an opportunity cost even when the bill does not increase.
Scheduled shutdown can reduce compute cost only if service availability permits it.

## Sizing and storage

Start a staging trial with 2 vCPU, 4 GiB application memory, and 40 GiB gp3 storage.
These are trial limits, not minimum requirements or a production recommendation.
Leave additional memory for the host, ingress, OAuth proxy, and a sibling service.
Measure peak ingestion memory, queue growth, CPU, latency, and disk growth with representative documents.
Test an out-of-memory failure before accepting limits.

The default configuration uses local AGFS, a SQLite queue, and a local vector backend.
Keep the complete application state together on a POSIX block filesystem.
POSIX describes common file and locking behavior.
Do not copy active SQLite files as a consistency guarantee.

Fargate temporary storage disappears when tasks stop.
Fargate EBS task storage does not provide a general persistent-volume replacement for service task replacement.
Do not assume a replacement task can attach the previous service task's volume.
EFS provides network file storage, but this plan does not verify its locking behavior for these backends.
An S3 file backend alone does not migrate the queue, vector index, or every other state file.
Fargate remains blocked until every state component has a tested persistence and recovery design.

Self-managed ECS on EC2 can use host storage, but placement must keep the writer with its volume.
Do not run two writers against this directory. Drain the first task before moving storage.

## Identity boundary

Use one browser hostname and a separate private API hostname.
The browser route passes through a tenant-specific OAuth proxy.
OAuth is a protocol that permits an application to use an identity provider.
Entra authenticates the person. OpenViking still authorizes its native API calls.
The browser may therefore also require a native user key.
Do not inject a shared root key to remove this second requirement.

The API route does not redirect to an HTML login page.
It validates native credentials through OpenViking before forwarding any request.
Keep `server.auth_mode` set to `api_key` for this design.
Do not replace it with `oidc` without proving compatibility with every existing client.
Invalid or missing API credentials must return an error, not a successful anonymous response.

LDAP is a directory protocol. Map directory identities to immutable Entra object IDs.
Do not use a changing email address as the only identity link.
The internal service must define synchronization, disabled-user handling, and deleted-user handling.
Set assignment-required behavior on the Entra enterprise application.
Assign reviewed users or groups to that application.
Confirm licensing, group membership behavior, and token revocation delays with the identity team.
Microsoft documents no nested-group expansion for application assignments.
Group-based assignment requires Entra ID P1 or P2.

## Deployment sequence

1. Confirm the exact internal identity schema.
   The identity team must supply its endpoint, schema version, and approval process.
2. Measure existing EC2 capacity.
   Reserve capacity separately for each application and the host.
3. Provision separate encrypted storage.
   Use separate paths and backup policies for OpenViking and a sibling service.
4. Prepare a non-root staging configuration.
   Verify image permissions, initialization, health checks, and native extensions.
5. Inject secrets at runtime.
   Fetch only approved secret ARNs through the host role into protected runtime files.
6. Test the proxy boundary in isolation.
   Prove missing and invalid credentials cannot reach the raw application.
7. Restore a backup into an isolated staging directory.
   Verify authenticated retrieval and writes before accepting the release.
8. Approve a production change window.
   Run the approved deployment integration only after the backup gate passes.

These inactive examples do not perform any deployment step.

## Shared-host separation

Use different Compose project names, containers, hostnames, credentials, and resource limits.
Use `/srv/openviking` and `/srv/sibling-service` as separate data roots.
Use separate encrypted volumes when independent restore and failure boundaries matter.
Separate secrets by application and environment.
Do not mount the Docker socket inside either application or the OAuth proxy.
A shared Docker host still shares a kernel and administrators.
Use separate hosts if that trust boundary is unacceptable.

## Validation

1. Test browser access without a session.
   The browser must reach Entra rather than raw OpenViking content.
2. Test an unassigned Entra user.
   The enterprise application must deny access.
3. Test API access without a key.
   The gateway must return 401 or 403 without a login redirect.
4. Test an invalid native key.
   The gateway must return 401 or 403 without application content.
5. Test a scoped native user key.
   The client must retain its existing API behavior and tenant boundary.
6. Test host port and network exposure.
   Only the approved ingress route can reach the container network.
7. Test an isolated restore.
   Confirm the queue, files, vector index, and native authorization still work.

## Backup and rollback

Use a planned write pause or a version-supported consistent backup method.
Snapshot the complete encrypted volume after the consistency boundary succeeds.
Record the image digest, schema version, configuration version, and snapshot ID together.
Keep snapshot encryption keys available during the retention period.
Retain at least one separately protected backup and test restoration regularly.

For rollback, stop the new writer during an approved change window.
Restore the previous compatible state to a separate volume.
Start the previous image digest against that restored volume.
Do not run an old image against migrated state without a compatibility test.
Route traffic back only after authenticated acceptance tests pass.

## Known limitations

The internal Graph contract, enterprise role ARNs, model endpoints, and backup integrations remain unknown.
These examples do not establish production SSO or an AWS deployment pipeline.

## Primary references

- [AWS ECS EBS volumes](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ebs-volumes.html): new-volume attachment and service-task deletion rules.
- [Microsoft application assignments](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/assign-user-or-group-access-portal): assignment requirements, licensing, and nested-group limits.

AWS documents that service-managed task volumes delete when the task ends.
AWS also documents that task attachment requires a new volume, not an existing volume.
These restrictions block a direct durable local-state migration to a Fargate service.
