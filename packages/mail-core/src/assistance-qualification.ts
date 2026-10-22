import type { NativeAssistance } from './assistance.ts';
import type { NativeTranslation } from './translation.ts';

// The evidence recorder compiled only into the assistance qualification build.
export interface NativeQualification {
  // Starts a new evidence file and describes this device.
  readonly begin: () => Promise<unknown>;
  readonly record: (line: string) => Promise<unknown>;
}

export type QualificationModules = () => Readonly<{
  assistance: NativeAssistance & NativeTranslation;
  qualification: NativeQualification;
}>;

// Only the `assistance-qualification` build substitutes a synthetic corpus run (#625). Every other
// build, including production, never looks its modules up.
export const startAssistanceQualification = (
  _modules: QualificationModules,
): void => undefined;
