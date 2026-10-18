import type { ComponentProps, ReactNode } from 'react';
import type { SplitHostCommands } from 'react-native-screens/experimental';

import { Navigator, useGlobalSearchParams } from 'expo-router';
import { SplitView } from 'expo-router/unstable-split-view';
import { useImperativeHandle, useState } from 'react';
import { Platform, StyleSheet } from 'react-native';
import { ScreenStack } from 'react-native-screens';

import { BackScreen } from './back-navigation.tsx';
import { usePalette } from './theme.ts';

type Props = Omit<ComponentProps<typeof SplitView>, 'children'> & {
  readonly primary: ReactNode;
  readonly supplementary: ReactNode;
  readonly composer: ReactNode;
};
const fill = StyleSheet.create({ page: { flex: 1 } });

export function MailNavigation({
  primary,
  supplementary,
  composer,
  ...props
}: Props) {
  if (Platform.OS === 'ios' && !Platform.isPad) {
    return (
      <PhoneMailNavigation
        {...props}
        primary={primary}
        supplementary={supplementary}
        composer={composer}
      />
    );
  }
  return (
    <SplitView {...props}>
      <SplitView.Column>{primary}</SplitView.Column>
      <SplitView.Column>{supplementary}</SplitView.Column>
    </SplitView>
  );
}

function PhoneMailNavigation({
  primary,
  supplementary,
  composer,
  ref,
  topColumnForCollapsing,
  testID,
}: Props) {
  const [column, setColumn] = useState<
    Parameters<SplitHostCommands['show']>[0]
  >(topColumnForCollapsing ?? 'supplementary');
  useImperativeHandle(ref, () => ({ show: setColumn }), []);
  const { id } = useGlobalSearchParams<{ id?: string }>();
  const colors = usePalette();
  const page = [fill.page, { backgroundColor: colors.surfaceContent }];
  return (
    <Navigator>
      <ScreenStack
        testID={testID}
        style={page}>
        <BackScreen
          screenId="mailboxes"
          testID="mailboxes-screen"
          activityState={2}
          accessibilityElementsHidden={column !== 'primary'}
          headerConfig={{ hidden: true }}
          style={page}>
          {primary}
        </BackScreen>
        {column === 'primary' ? null : (
          <BackScreen
            screenId="inbox"
            testID="inbox-screen"
            activityState={2}
            accessibilityElementsHidden={column === 'secondary'}
            headerConfig={{ hidden: true }}
            style={page}
            gestureEnabled>
            {supplementary}
          </BackScreen>
        )}
        {column === 'secondary' && id !== undefined ? (
          <MailRoutes covered={composer !== null} />
        ) : null}
        {composer === null ? null : (
          <BackScreen
            screenId="composer"
            testID="composer-screen"
            activityState={2}
            headerConfig={{ hidden: true }}
            style={page}
            gestureEnabled
            preventNativeDismiss>
            {composer}
          </BackScreen>
        )}
      </ScreenStack>
    </Navigator>
  );
}

// Each URL entry keeps its own native screen and Back action, including Thread history.
function MailRoutes({ covered }: { readonly covered: boolean }) {
  const { state, descriptors } = Navigator.useContext();
  const colors = usePalette();
  return state.routes.slice(0, state.index + 1).map((route, index) =>
    route.name === 'index' ? null : (
      <BackScreen
        key={route.key}
        screenId={route.key}
        testID="reader-screen"
        activityState={2}
        accessibilityElementsHidden={covered || index !== state.index}
        headerConfig={{ hidden: true }}
        style={[fill.page, { backgroundColor: colors.surfaceContent }]}
        gestureEnabled>
        {descriptors[route.key]?.render()}
      </BackScreen>
    ),
  );
}
