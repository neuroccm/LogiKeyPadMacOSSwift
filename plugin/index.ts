import { PluginSDK } from '@logitech/plugin-sdk';
import { Bridge } from './src/bridge';
import { makeActions } from './src/devpad-actions';

const bridge = new Bridge();
bridge.start();

const pluginSDK = new PluginSDK();
for (const action of makeActions(bridge)) {
  pluginSDK.registerAction(action);
}

try {
  await pluginSDK.connect();
  console.log('[devpad] LogiKeyPad Dev Pad connected to Logi Plugin Service');
} catch (err) {
  // Standalone runs (no Logi Plugin Service) land here: LPS normally
  // injects the WebSocket URL when it launches the plugin. Keep the
  // bridge alive so the failure is visible instead of a crash loop.
  console.error(`[devpad] Logi Plugin Service unavailable (launch via Options+ link): ${err instanceof Error ? err.message : err}`);
}
