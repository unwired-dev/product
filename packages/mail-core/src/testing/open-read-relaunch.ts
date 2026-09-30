import { createMockMailSession } from './mock-session.ts';

export const loadInitialMessages =
  createMockMailSession('open-read-relaunch').mail.list;
