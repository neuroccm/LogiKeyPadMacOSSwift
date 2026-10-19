import { connect, type Socket } from 'node:net';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

/**
 * Bridge to the LogiKeyPad Swift app (127.0.0.1:47831, newline JSON).
 * Reconnects with capped backoff. sendKey returns false when the app
 * is unreachable so callers can run their direct fallback.
 */
export class Bridge {
  private socket: Socket | null = null;
  private ready = false;
  private buffer = '';
  private backoffMs = 1000;
  private stopped = false;

  start(): void {
    this.stopped = false;
    this.connect();
  }

  private connect(): void {
    if (this.stopped) return;
    const sock = connect({ host: '127.0.0.1', port: 47831 });
    this.socket = sock;
    sock.setEncoding('utf8');

    sock.on('connect', () => {
      this.backoffMs = 1000;
      const token = this.readToken();
      this.send({ v: 1, type: 'hello', token });
    });
    sock.on('data', (chunk: string) => this.consume(chunk));
    sock.on('error', () => { /* handled by close */ });
    sock.on('close', () => {
      this.ready = false;
      this.socket = null;
      if (this.stopped) return;
      const wait = this.backoffMs;
      this.backoffMs = Math.min(this.backoffMs * 2, 10_000);
      setTimeout(() => this.connect(), wait).unref?.();
    });
  }

  private readToken(): string {
    try {
      const p = join(homedir(), 'Library', 'Application Support', 'LogiKeyPad', 'bridge-token');
      return readFileSync(p, 'utf8').trim();
    } catch {
      return '';
    }
  }

  private consume(chunk: string): void {
    this.buffer += chunk;
    if (this.buffer.length > 256 * 1024) { this.buffer = ''; return; }
    let idx: number;
    while ((idx = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, idx);
      this.buffer = this.buffer.slice(idx + 1);
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line) as { type?: string; id?: string; ok?: boolean; text?: string };
        if (msg.type === 'hello') { this.ready = true; console.log('[devpad] bridge ready'); }
        if (msg.type === 'result') console.log(`[devpad] ${msg.id}: ${msg.ok ? 'ok' : 'fail'} — ${msg.text ?? ''}`);
        if (msg.type === 'state') console.log(`[devpad] state: ${msg.text ?? ''}`);
      } catch { /* ignore malformed lines */ }
    }
  }

  private send(obj: unknown): void {
    this.socket?.write(`${JSON.stringify(obj)}\n`);
  }

  /** Returns true when the key press was delivered to the Swift app. */
  sendKey(id: string): boolean {
    if (!this.ready || !this.socket) return false;
    this.send({ v: 1, type: 'key', id });
    return true;
  }
}
