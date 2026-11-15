import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';

const isNoticeFile = (name) =>
  /^(?:licen[cs]e|copying|notice|unlicense)(?:$|[._-])/iu.test(name);

// Keep embedded vendor notices, but never descend into another npm dependency.
export function noticeFiles(directory, recursive = false, relative = '') {
  return readdirSync(path.join(directory, relative), { withFileTypes: true })
    .toSorted((a, b) => (a.name < b.name ? -1 : Number(a.name > b.name)))
    .filter((entry) => !['node_modules', '.git', '.build'].includes(entry.name))
    .filter((entry) => {
      if (entry.isDirectory()) {
        return true;
      }
      return entry.isFile() && isNoticeFile(entry.name);
    })
    .flatMap((entry) => {
      const file = path.join(relative, entry.name);
      if (entry.isDirectory()) {
        return recursive ? noticeFiles(directory, true, file) : [];
      }
      const text = readFileSync(path.join(directory, file), 'utf8');
      return text.trim() ? [{ file, text }] : [];
    });
}
