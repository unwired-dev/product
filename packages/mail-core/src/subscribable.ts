// A value hosts read synchronously and subscribe to, as `useSyncExternalStore` expects.
export function createSubscribable<A>(initial: A) {
  let value = initial;
  const listeners = new Set<() => void>();
  return {
    getSnapshot: () => value,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    set: (next: A) => {
      value = next;
      for (const listener of listeners) {
        listener();
      }
    },
  };
}
