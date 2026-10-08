import 'fast-text-encoding';
import { AppRegistry } from 'react-native';

import { keepGmailFresh } from './src/freshness.ts';
import { InboxWindow } from './src/window.tsx';

AppRegistry.registerComponent('UnwiredMail', () => InboxWindow);
keepGmailFresh();
