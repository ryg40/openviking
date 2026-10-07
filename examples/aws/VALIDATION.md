<a id="validation-record"></a>

# Validation checks

## Scope

These checks validate documentation and inactive examples.
They do not establish AWS, Entra, or live proxy acceptance.

| Check | Result |
| --- | --- |
| YAML parsing | Passed for Compose, identity options, and workflows |
| CloudFormation | Both templates passed `cfn-lint` |
| GitHub Actions syntax | Both mockups passed `actionlint` 1.7.7 |
| Embedded workflow shell | Every `run` block passed `bash -n` |
| Proxy configuration format | `oauth2-proxy.cfg` passed Python TOML parsing |
| Example Compose | Passed `config --no-env-resolution --quiet` with dummy digest values |
| Explainer coverage | Every machine-readable example has its own Markdown explainer |
| Local example links | All targets exist |

The example Compose check does not load real runtime secret files.
The Actions check does not resolve placeholder action references or supply missing enterprise scripts.
Not verified: the optional ShellCheck integration of `actionlint`.
TOML parsing does not prove that a particular oauth2-proxy release accepts every option.
Not verified: NGINX binary validation and proxy integration tests.

## Outstanding checks

1. Confirm the real internal identity-service schema.
   The proposed `idp` files remain illustrative until this contract exists.
2. Test all pinned images as the selected non-root users.
   Verify initialization, state access, and health checks.
3. Run the authentication matrix in an isolated staging network.
   Test assigned users, unassigned users, native keys, and forged headers.
4. Test representative ingestion and recovery.
   Confirm resource limits and complete storage restoration.
5. Implement and review the enterprise CI integrations.
   Test role denial, scan failure, backup failure, and rollback failure.

## Service boundary

The validation uses only syntax checks of the example files.
It does not restart containers, deploy configurations, rotate credentials, or create AWS or Entra resources.
