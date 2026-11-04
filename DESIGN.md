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
- Service connections use three task-based categories: Apple ecosystem, NAS,
  and other services. NAS shows one configured device summary; discovery and
  credential editing appear only while setting up or changing that connection.
- Show default write destinations next to their selectors. Keep current health,
  failure reasons and recovery actions visible. Detailed developer deployment
  controls belong in a clearly named secondary window, not unexplained cards.
- Logs show the latest retained events first, explain their consequence and
  preserve a readable selection without a focus frame around the whole list.
  Task metadata is bounded and excludes prompt, output, paths and credentials.
- Empty sections are removed. Completed diagnostic sample tasks do not become
  permanent product cards. Only live registered applications appear in the app list.
- Fast mode and parallelism use framed 36-point controls, consistent with the
  adjacent model and effort selectors. Every icon control has a readable name.
- Healthy flows update automatically. Show recovery actions only for an actual
  failure or a decision the user needs to make. Preserve keyboard operation,
  accessible state labels, reduced motion and readable dark-mode semantics.
- Background refresh belongs in the fixed card header. Do not insert a spinner
  row which shifts the settings while the user is reading or clicking them.
- Errors state the current failure, its consequence and the next useful action.
  Read the operation receipt before reporting completion. Default write locations
  never imply a restriction on reading or searching other authorized locations.
- Finder actions carry the same approved ARL artwork as the main application.
  Primary and secondary actions share the same geometry throughout the app.
