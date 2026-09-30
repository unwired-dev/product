import { createMockMailSession } from './mock-session.ts';

export const loadInitialMessages =
  createMockMailSession('mail-unavailable').mail.list;
