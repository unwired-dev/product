// The DESIGN.md tokens ("Graphite & Cinnabar"); each client picks its platform's type ramp.
export const spacing = { xs: 4, s: 8, m: 12, l: 16, xl: 20 };

export const radius = {
  control: 6,
  row: 7,
  card: 10,
  window: 16,
  bubble: 20,
  chip: 14,
};

export const palette = {
  light: {
    accentFill: '#3A3D44',
    accentOnFill: '#FFFFFF',
    accentInk: '#3A3D44',
    accentSelectionSubtle: 'rgba(58, 61, 68, 0.12)',
    onDeviceInk: '#A3321F',
    onDeviceSurface: '#FBEEEA',
    brandDeep: '#15171B',
    brandOnDeep: '#FFFFFF',
    brandSeal: '#C2412A',
    brandOnSeal: '#FFFFFF',
    brandMonogram: '#15171B',
    textPrimary: 'rgba(0, 0, 0, 0.85)',
    textSecondary: 'rgba(0, 0, 0, 0.6)',
    surfaceContent: '#FFFFFF',
    surfaceSidebar: '#F3F2F5',
    surfaceBubble: '#F1F1F4',
    fillQuiet: 'rgba(0, 0, 0, 0.05)',
    fillTrack: 'rgba(0, 0, 0, 0.09)',
    separator: 'rgba(0, 0, 0, 0.1)',
    statusWarning: '#C93400',
    statusDestructive: '#D70015',
    // Glass controls of 48pt or less.
    smallGlassShadow: '0px 2px 8px rgba(0, 0, 0, 0.08)',
  },
  dark: {
    accentFill: '#6A6E78',
    accentOnFill: '#FFFFFF',
    accentInk: '#C8CBD2',
    accentSelectionSubtle: 'rgba(200, 203, 210, 0.16)',
    onDeviceInk: '#FF9E88',
    onDeviceSurface: '#3A2420',
    brandDeep: '#15171B',
    brandOnDeep: '#FFFFFF',
    brandSeal: '#C2412A',
    brandOnSeal: '#FFFFFF',
    brandMonogram: '#6A6E78',
    textPrimary: 'rgba(255, 255, 255, 0.85)',
    textSecondary: 'rgba(255, 255, 255, 0.55)',
    surfaceContent: '#1E1E1E',
    surfaceSidebar: '#2A2A2C',
    surfaceBubble: '#2C2C2E',
    fillQuiet: 'rgba(255, 255, 255, 0.06)',
    fillTrack: 'rgba(255, 255, 255, 0.16)',
    separator: 'rgba(255, 255, 255, 0.1)',
    statusWarning: '#FFB340',
    statusDestructive: '#FF6961',
    smallGlassShadow: '0px 2px 8px rgba(0, 0, 0, 0.3)',
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
  },
  ios: {
    largeTitle: style(34, 41, '700'),
    headline: style(17, 22, '600'),
    body: style(17, 22, '400'),
    subheadline: style(15, 20, '400'),
    footnote: style(13, 18, '400'),
  },
  reading: {
    subject: style(20, 25, '700'),
    body: style(15, 22, '400'),
  },
};
