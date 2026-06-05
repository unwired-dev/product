export {
  actionGeneric as action,
  httpActionGeneric as httpAction,
  internalActionGeneric as internalAction,
  internalMutationGeneric as internalMutation,
  internalQueryGeneric as internalQuery,
  mutationGeneric as mutation,
  queryGeneric as query,
} from 'convex/server';

export type {
  GenericActionCtx as ActionCtx,
  GenericDatabaseReader as DatabaseReader,
  GenericDatabaseWriter as DatabaseWriter,
  GenericMutationCtx as MutationCtx,
  GenericQueryCtx as QueryCtx,
} from 'convex/server';
