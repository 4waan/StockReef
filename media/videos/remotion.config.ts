import {Config} from '@remotion/cli/config';

// Sandboxes without Remotion's own Chrome download can point at a local Chromium headless shell.
if (process.env.REMOTION_BROWSER) Config.setBrowserExecutable(process.env.REMOTION_BROWSER);
Config.setVideoImageFormat('jpeg');
