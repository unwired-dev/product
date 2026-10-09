# Convex production deploys

The [Convex workflow](../.github/workflows/convex.yml) deploys `packages/convex`
(functions, schema and auth configuration) to the production Convex deployment.
It runs only when dispatched:

```sh
gh workflow run convex.yml --ref main
gh run watch
```

The job runs in the `convex-production` GitHub environment. Its deployment
branch policy admits only `main`, so a run dispatched from another branch
cannot read the deploy key. Runs execute one at a time, with up to 100 pending
runs queued; additional runs are cancelled when the queue is full.

Deployment environment variables (`APPLE_BUNDLE_ID`, `GOOGLE_PRODUCT_CLIENT_IDS`
and the rest declared in
[`convex.config.ts`](../packages/convex/convex/convex.config.ts)) live on the
Convex deployment, not in GitHub. Set them before the first deploy in the Convex
dashboard or, using the [local deployment configuration](../README.md#local-development),
run this from the repository root:

```sh
mise exec -- pnpm --filter @private-email/convex exec -- convex env set \
  --env-file ../../.env.local --prod NAME 'value'
```

The hosts call whichever deployment their build's `CONVEX_URL` names; deploying
production does not change which backend existing TestFlight builds use.

## One-time setup

1. In the Convex dashboard, open the production deployment's settings and
   generate a [production deploy key](https://docs.convex.dev/cli/deploy-key-types#deployment-token)
   with only the [`deployment:deploy` permission](https://docs.convex.dev/team-management/role-actions#data-plane-and-runtime)
   enabled. The workflow does not need environment-variable or data permissions;
   deployment environment variables are configured separately as described above.
2. Store it in the environment, entering the key at the hidden prompt:

   ```sh
   gh secret set CONVEX_DEPLOY_KEY --env convex-production
   ```

The environment exists with its `main` branch policy. To recreate it, delete it
first so no other branch policy survives, then repeat step 2, because deleting
the environment also deletes its secret:

```sh
gh api -X DELETE repos/unwired-dev/product/environments/convex-production
gh api -X PUT repos/unwired-dev/product/environments/convex-production \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST repos/unwired-dev/product/environments/convex-production/deployment-branch-policies \
  -f name=main -f type=branch
```
