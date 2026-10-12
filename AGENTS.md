# StatBar agent notes

Follow `../AGENTS.md`. Native macOS menu-bar app, xcodegen project (`project.yml`), Swift 6 language mode, deployment target macOS 27 (all projects target macOS 27; use current APIs: Observation `@Observable`, Swift concurrency).

- Concurrency: `StatMonitor`, the popover UI and the app delegate are `@MainActor`. Sampling is a `Task.sleep` loop (`StatMonitor.startSampling`), network reachability and screen sleep/wake are async sequences; cancel the tasks when pausing.
- After editing `project.yml`, run `xcodegen generate`. Check with `xcodebuild -scheme StatBar -destination 'platform=macOS' test`.
