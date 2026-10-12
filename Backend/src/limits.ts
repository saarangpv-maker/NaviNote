// In-memory abuse and spend limits. One process only: behind several
// instances each would count separately (documented in the README).

export type Clock = () => number;

/// At most `limit` requests per key within `windowMs`.
export class SlidingWindowLimiter {
  readonly #limit: number;
  readonly #windowMs: number;
  readonly #now: Clock;
  readonly #maxKeys: number;
  readonly #hits = new Map<string, number[]>();

  constructor(options: { limit: number; windowMs: number; now?: Clock; maxKeys?: number }) {
    this.#limit = options.limit;
    this.#windowMs = options.windowMs;
    this.#now = options.now ?? Date.now;
    this.#maxKeys = options.maxKeys ?? 10_000;
  }

  /// Records a request for `key` if allowed. Returns seconds to wait if not.
  take(key: string): { allowed: true } | { allowed: false; retryAfterSeconds: number } {
    const now = this.#now();
    const recent = (this.#hits.get(key) ?? []).filter((time) => now - time < this.#windowMs);
    if (recent.length >= this.#limit) {
      const oldest = recent[0] ?? now;
      this.#hits.set(key, recent);
      return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil((oldest + this.#windowMs - now) / 1000)) };
    }
    recent.push(now);
    this.#hits.delete(key);
    this.#hits.set(key, recent);
    // Bound memory: drop the least recently used keys.
    while (this.#hits.size > this.#maxKeys) {
      const first = this.#hits.keys().next();
      if (first.done === true) break;
      this.#hits.delete(first.value);
    }
    return { allowed: true };
  }
}

/// A global cap on requests per UTC day, the last line of spend control.
export class DailyCap {
  readonly #cap: number;
  readonly #now: Clock;
  #day = "";
  #count = 0;

  constructor(cap: number, now: Clock = Date.now) {
    this.#cap = cap;
    this.#now = now;
  }

  take(): boolean {
    const day = new Date(this.#now()).toISOString().slice(0, 10);
    if (day !== this.#day) {
      this.#day = day;
      this.#count = 0;
    }
    if (this.#count >= this.#cap) return false;
    this.#count += 1;
    return true;
  }
}

export interface Limits {
  perInstall: SlidingWindowLimiter;
  perInstallDaily: SlidingWindowLimiter;
  perAddress: SlidingWindowLimiter;
  daily: DailyCap;
  /** Banknote photos per UTC day, on top of the overall cap. */
  imageDaily: DailyCap;
}

export function standardLimits(dailyCap: number, now: Clock = Date.now, imageDailyCap = 100): Limits {
  const tenMinutes = 10 * 60 * 1000;
  return {
    perInstall: new SlidingWindowLimiter({ limit: 20, windowMs: tenMinutes, now }),
    perInstallDaily: new SlidingWindowLimiter({ limit: 200, windowMs: 24 * 60 * 60 * 1000, now }),
    perAddress: new SlidingWindowLimiter({ limit: 60, windowMs: tenMinutes, now }),
    daily: new DailyCap(dailyCap, now),
    imageDaily: new DailyCap(imageDailyCap, now),
  };
}
