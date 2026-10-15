# Assets

All artwork here is original, made for Keepwatch, and licensed Apache-2.0 with the rest of the repository.

- `icon.svg`: the app icon (source of truth). An eye whose upper lid is a laptop lid, with a teal "awake" light.
- `logo.svg` / `logo-dark.svg`: the wordmark for light and dark backgrounds. Self-contained, because GitHub won't load linked files inside an SVG shown as an image.
- `../Resources/AppIcon-1024.png`: `icon.svg` rendered at 1024 px. To regenerate it:

  ```sh
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --default-background-color=00000000 \
    --window-size=1024,1024 --screenshot=Resources/AppIcon-1024.png "file://$PWD/assets/icon.svg"
  ```
