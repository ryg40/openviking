# Existing-host storage template

## Purpose

`storage.cfn.yml` creates one encrypted EBS volume and attaches it to an existing EC2 instance.
CloudFormation manages AWS resources from a template.
This template does not format, mount, initialize, or back up the volume.

## Prerequisites

Provide an approved existing instance and its availability zone.
Provide an existing KMS key with the required EBS permissions.
KMS manages encryption keys.
Confirm the host has capacity and supports the requested attachment.

## Configuration groups

- Parameters select the host, zone, encryption key, and volume size.
- `StateVolume` creates encrypted gp3 storage with retained lifecycle behavior.
- Tags identify the application and an existing backup policy selector.
- `StateAttachment` attaches the volume without formatting it.
- Outputs expose the volume ID, not secret values.

## Replacement fields

Supply `ExistingInstanceId`, `AvailabilityZone`, and `KmsKeyArn`.
Replace `REPLACE_APPROVED_POLICY` with a real backup selection tag.
The tag does nothing unless a matching approved AWS Backup plan exists.
Size the volume from measured data growth and retention requirements.

## Security boundary

Use a deployment role scoped to approved instances, tags, volumes, and encryption keys.
Store OpenViking data separately from the data of a sibling service.
Retain access to the KMS key for the full backup retention period.
A retained volume is not a separate backup.

## Deployment steps

1. Run `cfn-lint storage.cfn.yml`.
   Resolve errors before requesting a change set.
2. Create an approved CloudFormation change set.
   Inspect every resource before execution.
3. Execute the approved change set.
   This action creates billable storage and attaches it to the host.
4. Identify the attached disk by its EBS volume ID.
   Nitro instances use NVMe device names instead of the requested attachment name.
5. Prepare a filesystem only after proving the disk is empty.
   Mount it at the approved OpenViking state path.

## Validation

1. Inspect volume encryption and availability zone.
   Both must match the approved plan.
2. Inspect the mounted filesystem's backing volume ID.
   It must match the template output.
3. Run an isolated backup and restore test.
   Confirm native authenticated retrieval after restoration.

## Costs

Budget for gp3 capacity, additional provisioned performance, snapshots, and retained resources.
Deleting the stack does not remove the retained volume or stop its storage charges.

## Rollback

Stop the application writer during an approved change window before detaching storage.
Retain the old volume until restoration and application acceptance tests pass.
Do not force-detach a mounted, active volume.

## Known limitations

The template does not create a backup plan or establish application-consistent snapshots.
A CloudFormation delete or update can detach storage despite the volume retention policy.
Treat storage stack changes as service maintenance.

Warning: Formatting the wrong disk destroys data.
