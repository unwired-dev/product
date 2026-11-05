// The DESIGN.md tokens ("Graphite & Cinnabar"); each client picks its platform's type ramp.
export const spacing = { xs: 4, s: 8, m: 12, l: 16, xl: 20 };

// The iPad Inbox frames scale the Mac list recipe by 1.15.
export const ipadListScale = 1.15;

export const radius = {
  control: 6,
  row: 7,
  card: 10,
  menu: 12,
  formatPanel: 34,
  closeQuestion: 36,
  alertMac: 22,
  alertTouch: 32,
  // The iPhone and iPad invitation card.
  touchCard: 18,
  window: 16,
  // iPad Sign In's deep brand panel.
  brandPanel: 24,
  // iPad's centred setup sheet, as Add a Mailbox draws it.
  ipadSheet: 29.095,
  bubble: 20,
  chip: 14,
  mailboxGroup: 22,
  // iPhone's Profile Switcher above the Mailboxes groups.
  profileSwitcher: 14,
  // iPhone's Move to… sheet: its top corners, search field and inset row groups.
  sheet: 38,
  searchField: 18,
  insetGroup: 22,
  settingsDetail: 16.923076629638672,
};

export const palette = {
  light: {
    accentFill: '#3A3D44',
    accentOnFill: '#FFFFFF',
    accentInk: '#3A3D44',
    accentSelectionSubtle: 'rgba(58, 61, 68, 0.12)',
    // The iPad Palette frames' outline around the focused command query.
    focusRing: 'rgba(58, 61, 68, 0.32)',
    onDeviceInk: '#A3321F',
    onDeviceSurface: '#FBEEEA',
    brandDeep: '#15171B',
    brandOnDeep: '#FFFFFF',
    brandSeal: '#C2412A',
    brandOnSeal: '#FFFFFF',
    brandMonogram: '#15171B',
    // The Recovery Key's well on brand deep, alike in Light and Dark.
    brandWell: 'rgba(255, 255, 255, 0.08)',
    brandWellBorder: 'rgba(255, 255, 255, 0.16)',
    // Sign in with Apple follows Apple's black and white button styles.
    appleButton: '#000000',
    appleOnButton: '#FFFFFF',
    textPrimary: 'rgba(0, 0, 0, 0.85)',
    textSecondary: '#4F4F54',
    surfaceContent: '#FFFFFF',
    surfaceSidebar: '#F3F2F5',
    // The iPad's floating sidebar panels, as the frames' glass reads over the content surface.
    surfacePanel: '#F8F8F8',
    // Mac sidebars' glass; Dark backs it so secondary text keeps 4.5:1 over bright desktops.
    materialSidebarBacking: 'transparent',
    surfaceBubble: '#F1F1F4',
    // The tint under iPhone and iPad Liquid Glass, measured on iOS 27 so glass over the content
    // surface renders the frames' glass fill: #F8F8F8 in Light, #1A1A1A in Dark.
    glassTint: '#C6C6C6',
    fillQuiet: 'rgba(0, 0, 0, 0.05)',
    // A pop-up button's disc within a grouped row.
    fillControl: 'rgba(0, 0, 0, 0.08)',
    fillTrack: 'rgba(0, 0, 0, 0.09)',
    separator: 'rgba(0, 0, 0, 0.1)',
    statusWarning: '#C93400',
    statusDestructive: '#D70015',
    // Glass controls of 48pt or less.
    smallGlassShadow: '0px 2px 8px rgba(0, 0, 0, 0.08)',
    largeGlassShadow: '0px 4px 16px rgba(0, 0, 0, 0.08)',
    menuGlassShadow: '0px 8px 24px rgba(0, 0, 0, 0.16)',
    scrimTouch: 'rgba(0, 0, 0, 0.22)',
    // Menus, popovers and sheets, which float above the content.
    menuShadow: '0px 8px 24px rgba(0, 0, 0, 0.16)',
    // The deep graphite toast above the floating search bar, alike in Light and Dark.
    toastShadow: '0px 6px 9px rgba(0, 0, 0, 0.18)',
  },
  dark: {
    accentFill: '#6A6E78',
    accentOnFill: '#FFFFFF',
    accentInk: '#C8CBD2',
    accentSelectionSubtle: 'rgba(200, 203, 210, 0.16)',
    focusRing: 'rgba(106, 110, 120, 0.28)',
    onDeviceInk: '#FF9E88',
    onDeviceSurface: '#3A2420',
    brandDeep: '#15171B',
    brandOnDeep: '#FFFFFF',
    brandSeal: '#C2412A',
    brandOnSeal: '#FFFFFF',
    brandMonogram: '#6A6E78',
    brandWell: 'rgba(255, 255, 255, 0.08)',
    brandWellBorder: 'rgba(255, 255, 255, 0.16)',
    appleButton: '#FFFFFF',
    appleOnButton: '#000000',
    textPrimary: 'rgba(255, 255, 255, 0.85)',
    textSecondary: '#B0B0B5',
    surfaceContent: '#1E1E1E',
    surfaceSidebar: '#2A2A2C',
    surfacePanel: '#1A1A1A',
    materialSidebarBacking: 'rgba(42, 42, 44, 0.92)',
    surfaceBubble: '#2C2C2E',
    glassTint: '#3B3B3B',
    fillQuiet: 'rgba(255, 255, 255, 0.06)',
    fillControl: 'rgba(255, 255, 255, 0.07)',
    fillTrack: 'rgba(255, 255, 255, 0.16)',
    separator: 'rgba(255, 255, 255, 0.1)',
    statusWarning: '#FFB340',
    statusDestructive: '#FF6961',
    smallGlassShadow: '0px 2px 8px rgba(0, 0, 0, 0.3)',
    largeGlassShadow: '0px 4px 16px rgba(0, 0, 0, 0.3)',
    menuGlassShadow: '0px 18px 48px rgba(0, 0, 0, 0.45)',
    // The iPad Compose frames dim the #1E1E1E content to #121212.
    scrimTouch: 'rgba(0, 0, 0, 0.4)',
    menuShadow: '0px 18px 48px rgba(0, 0, 0, 0.45)',
    toastShadow: '0px 6px 9px rgba(0, 0, 0, 0.18)',
  },
};

// A Mail Profile's Color fills its monogram behind white; Graphite is the brand monogram.
export const profilePalette = {
  light: {
    graphite: palette.light.brandMonogram,
    blue: '#0A58CA',
    indigo: '#3634A3',
    purple: '#8944AB',
    pink: '#C2185B',
    teal: '#0E7490',
    green: '#237A3A',
    brown: '#7A5C3E',
  },
  dark: {
    graphite: palette.dark.brandMonogram,
    blue: '#3B6FD6',
    indigo: '#5E5CE6',
    purple: '#9558BB',
    pink: '#D6336C',
    teal: '#117C97',
    green: '#2A8443',
    brown: '#8C6A4A',
  },
};

const style = (
  fontSize: number,
  lineHeight: number,
  fontWeight: '400' | '600' | '700',
) => ({ fontSize, lineHeight, fontWeight });

export const typography = {
  macos: {
    largeTitle: style(26, 32, '400'),
    title3Emphasized: style(15, 20, '600'),
    body: style(13, 16, '400'),
    bodyEmphasized: style(13, 16, '600'),
    subheadline: style(11, 14, '400'),
    subheadlineEmphasized: style(11, 14, '600'),
  },
  ios: {
    largeTitle: style(34, 41, '700'),
    headline: style(17, 22, '600'),
    body: style(17, 22, '400'),
    subheadline: style(15, 20, '400'),
    footnote: style(13, 18, '400'),
    caption1: style(12, 16, '400'),
    title3Emphasized: style(20, 25, '600'),
  },
  ipadList: {
    title3Emphasized: style(17.25, 23, '600'),
    body: style(14.95, 18.4, '400'),
    subheadline: style(12.65, 16.1, '400'),
  },
  reading: {
    subject: style(20, 25, '700'),
    body: style(15, 22, '400'),
  },
};
