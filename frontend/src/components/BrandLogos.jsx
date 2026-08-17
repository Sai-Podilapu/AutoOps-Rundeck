import React from "react";

/* Official-style brand marks for SSO buttons (multicolor, currentColor not used). */

export function GoogleLogo({ size = 18 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 48 48" aria-hidden="true">
      <path
        fill="#FFC107"
        d="M43.6 20.5H42V20H24v8h11.3C33.7 32.9 29.3 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.9 1.2 8 3.1l5.7-5.7C34.6 6.1 29.6 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.3-.4-3.5z"
      />
      <path
        fill="#FF3D00"
        d="M6.3 14.7l6.6 4.8C14.7 16 19 13 24 13c3.1 0 5.9 1.2 8 3.1l5.7-5.7C34.6 6.1 29.6 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"
      />
      <path
        fill="#4CAF50"
        d="M24 44c5.2 0 10-2 13.6-5.2l-6.3-5.2C29.2 35 26.7 36 24 36c-5.3 0-9.7-3.1-11.3-7.5l-6.5 5C9.6 39.6 16.2 44 24 44z"
      />
      <path
        fill="#1976D2"
        d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.1-4 5.6l6.3 5.2C41.4 36 44 30.5 44 24c0-1.3-.1-2.3-.4-3.5z"
      />
    </svg>
  );
}

export function MicrosoftLogo({ size = 16 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <rect x="1" y="1" width="10" height="10" fill="#F25022" />
      <rect x="13" y="1" width="10" height="10" fill="#7FBA00" />
      <rect x="1" y="13" width="10" height="10" fill="#00A4EF" />
      <rect x="13" y="13" width="10" height="10" fill="#FFB900" />
    </svg>
  );
}

export function AwsLogo({ size = 20 }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path
        d="M19.46 16.92c-.89.82-2.35 1.4-3.87 1.4-2.88 0-4.66-1.74-4.66-4.25 0-2.48 1.83-4.17 4.54-4.17 1.63 0 2.9.52 3.82 1.35l.89-1.25C19.12 9.07 17.5 8.4 15.42 8.4c-3.66 0-6.19 2.22-6.19 5.62 0 3.34 2.5 5.75 6.2 5.75 2.11 0 3.73-.64 4.86-1.63l-.83-1.22zM27 12.33c-1.12-2.73-2.92-3.88-5.34-3.88-3.08 0-4.7 2.05-4.7 4.96 0 2.94 1.7 4.98 4.79 4.98 2.28 0 4.14-1.07 5.25-3.67l-1.34-.69c-.79 1.83-2 2.65-3.83 2.65-2.02 0-3.32-1.37-3.32-3.65h8.65v-.7h-.16zm-8.49.19c.14-1.42 1-2.43 2.67-2.43 1.44 0 2.55.91 2.76 2.43h-5.43zM10.15 19.53L8.68 15h-.05l-1.47 4.53H5.6L3 8.65h1.66l1.73 5.72h.05l1.63-5.72h1.49l1.65 5.7h.05l1.71-5.7h1.63l-2.6 10.88h-1.85z"
        fill="#FF9900"
      />
      <path
        d="M25.75 21.05c-3.1 1.05-6.57 1.6-9.75 1.6-4.52 0-8.62-1-12.06-2.62.06-.05 10.17 6.47 21.81 1.02z"
        fill="#FF9900"
      />
      <path
        d="M26.79 20.32c-.08-.12-2.08-.34-2.88-.42.92-.08 2.87.1 2.94.22.07.13-.53 2.05-.73 2.97.23-.74 1.25-2.65.67-2.77z"
        fill="#FF9900"
      />
    </svg>
  );
}

export function AzureLogo({ size = 20 }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path d="M7 23.32l5.63-16.7 3.5.02L7 23.32z" fill="#0078D4" />
      <path
        d="M8.27 23.95L20.44 9.15h4.53L12.78 26.15H8.27v-2.2z"
        fill="#00A4EF"
      />
    </svg>
  );
}

export function OracleLogo({ size = 20 }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path
        d="M16 5.5C10.2 5.5 5.5 10.2 5.5 16s4.7 10.5 10.5 10.5S26.5 21.8 26.5 16 21.8 5.5 16 5.5zm0 17C12.4 22.5 9.5 19.6 9.5 16s2.9-6.5 6.5-6.5 6.5 2.9 6.5 6.5-2.9 6.5-6.5 6.5z"
        fill="#F80000"
      />
    </svg>
  );
}

export function HuaweiLogo({ size = 20 }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path
        d="M16 4l-4 6-5-2 1 7-7 2 7 2-1 7 5-2 4 6 4-6 5 2-1-7 7-2-7-2 1-7-5 2-4-6z"
        fill="#FF0000"
      />
    </svg>
  );
}
