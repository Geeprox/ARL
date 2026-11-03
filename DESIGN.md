# ARL native control interface

The product is a macOS infrastructure utility for ordinary Mac users. Preserve
the existing warm neutral surfaces, system type and restrained accent. Build
directly in SwiftUI and verify the installed interface.

- Use one compact card for each configurable service. The icon, service name
  and current status belong in that card's header. A healthy service without
  settings needs only its header; do not reserve an empty content block.
- Connection state uses a consistent seven-point dot and a short readable label.
  Green means current connection evidence; gray means inactive; the accent marks
  work in progress; amber marks an actionable problem. Never show a restored
  permission observation as a current successful connection.
- Use real application icons from registered protocol payloads. System service
  icons may use the corresponding installed system application's icon. Do not
  maintain a branded consumer-app list in ARL.
- Keep native menus and focus behavior. The complete padded control surface,
  including trailing whitespace and arrows, receives pointer input. Shared
  controls have a 36-point minimum height; toolbar and icon actions retain a
  minimum 40-point target.
- Card radius is 12 points, control radius six. Use the existing subtle border
  rather than decorative shadows. Keep short labels close to their values.
- Show default write destinations next to the corresponding selector. Put
  protocol, implementation and diagnostic details behind explicit disclosure.
- Healthy flows update automatically. Show recovery actions only for an actual
  failure or a decision the user needs to make. Preserve keyboard operation,
  accessible state labels, reduced motion and readable dark-mode semantics.
