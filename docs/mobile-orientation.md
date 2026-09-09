# Mobile orientation policy (iOS)

**Decided 2026-09-10.** The iPhone runs upright only (`portrait`); the iPad
rotates freely. The policy lives in one place:
`mobile/ios/Runner/AppDelegate.swift`,
`application(_:supportedInterfaceOrientationsFor:)`. The plist keeps listing
every orientation; UIKit intersects it with that mask.

## Why it is there and not somewhere obvious

- `Info.plist` `UISupportedInterfaceOrientations~ipad` does **nothing** in a
  Flutter app: the engine builds its orientation mask from the generic
  `UISupportedInterfaceOrientations` key and ignores the `~ipad` variant. A
  landscape-only `~ipad` key sat in the tree from 2026-09-04 with no effect.
- A Dart-side lock at startup (`SystemChrome.setPreferredOrientations` in
  `main()`) failed twice on a real iPad, both times silently: deciding by
  window size reads `Size.zero` before the first frame; asking the runner
  over a method channel runs before `didFinishLaunching` has registered the
  handler, and the size fallback then gives the same wrong answer. Do not
  reintroduce a startup lock with a fallback — a fallback in that position
  always returns the wrong answer exactly when it is needed.

## iPad landscape lock: tried, reverted (iPadOS 26)

The owner asked for a landscape-only iPad (the wide shell is built for it).
On iPadOS 26 (iPad Pro 13" M4, 26.6.1) an app's orientation mask is no longer
"refuse to rotate": with the OS's windowing, it is read as a **window aspect
constraint**. A portrait-held iPad showed a letterboxed landscape window —
black bands above and below, the wide shell in the middle at its landscape
proportion — rather than staying landscape. `UIRequiresFullScreen` does not
change this. The delegate was working as written; the platform interprets it
differently. There is no app-level way to force the iPad's screen orientation
on iPadOS 26, so the iPad is back to free rotation and shows the phone layout
in portrait. The iPhone keeps `portrait` — phones still follow the old rule.

If this request comes back, the answer is the paragraph above, not another
implementation.
