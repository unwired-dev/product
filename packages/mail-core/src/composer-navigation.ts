// Navigation away from an open composer: the composer registers how it finishes (completing
// recipients and saving), and every other destination asks to leave first. One request runs at a
// time, and a composer that cannot finish, or fails to, stays open for a later attempt.
export interface ComposerNavigation {
  readonly register: (finish: () => Promise<boolean>) => () => void;
  readonly leave: () => Promise<boolean>;
}

export function createComposerNavigation(): ComposerNavigation {
  let finish: (() => Promise<boolean>) | undefined = undefined;
  let pending = false;
  return {
    register: (next) => {
      finish = next;
      return () => {
        if (finish === next) {
          finish = undefined;
        }
      };
    },
    leave: async () => {
      if (pending) {
        return false;
      }
      pending = true;
      try {
        return (await finish?.()) ?? true;
      } catch {
        // A composer that failed to finish stays open; a later attempt can leave again.
        return false;
      } finally {
        pending = false;
      }
    },
  };
}
