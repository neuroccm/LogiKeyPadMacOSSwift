import { CommandAction } from '@logitech/plugin-sdk';
import { exec } from 'node:child_process';
import { ACTIONS, type ActionDef } from './catalog.generated';
import type { Bridge } from './bridge';

/**
 * One parameterized action class for the whole catalog.
 * Primary path: forward the press to the Swift app over the bridge.
 * Fallback (app not running): run the action's direct command if it has
 * one, otherwise tell the user to start LogiKeyPad.
 */
class DevPadAction extends CommandAction {
  readonly name: string;
  displayName: string;
  description: string;
  groupName: string;

  constructor(private readonly def: ActionDef, private readonly bridge: Bridge) {
    super();
    this.name = def.id;
    this.displayName = def.sub ? `${def.title} · ${def.sub}` : def.title;
    this.description = `LogiKeyPad Dev Pad — ${this.displayName}`;
    this.groupName = def.group;
  }

  onKeyDown(): void {
    if (this.bridge.sendKey(this.def.id)) return;
    if (this.def.fallback) {
      exec(this.def.fallback, (err) => {
        if (err) console.error(`[devpad] fallback failed for ${this.def.id}: ${err.message}`);
      });
      return;
    }
    exec(`osascript -e 'display dialog "LogiKeyPad app is not running. Launch LogiKeyPad.app so the keys have a repo to act on." buttons {"OK"} default button 1 with title "LogiKeyPad Dev Pad"'`);
  }
}

export function makeActions(bridge: Bridge): CommandAction[] {
  return ACTIONS.map((def) => new DevPadAction(def, bridge));
}
