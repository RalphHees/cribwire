/**
 * Prometheus metrics (backend.md §6: connections, event fan-out latency, APNs
 * error rates).
 *
 * Hand-rolled rather than pulled from a client library: the exposition format
 * needed here is a few dozen lines, and a metrics dependency would be one more
 * package with access to the process.
 *
 * Label values are fixed strings chosen in this file. No pairing id, device
 * id, token, or IP is ever used as a label — a metrics scrape must not become
 * the request log the rest of the service refuses to keep.
 */

export type LabelValues = Readonly<Record<string, string>>;

function labelKey(labels: LabelValues): string {
  const entries = Object.entries(labels).sort(([a], [b]) => a.localeCompare(b));
  return entries.map(([name, value]) => `${name}="${value}"`).join(',');
}

function renderName(name: string, labelSuffix: string): string {
  return labelSuffix === '' ? name : `${name}{${labelSuffix}}`;
}

interface Metric {
  readonly name: string;
  readonly help: string;
  readonly type: 'counter' | 'gauge' | 'histogram';
  render(): string[];
}

export class Counter implements Metric {
  readonly name: string;
  readonly help: string;
  readonly type = 'counter' as const;
  readonly #values = new Map<string, number>();

  constructor(name: string, help: string) {
    this.name = name;
    this.help = help;
  }

  inc(labels: LabelValues = {}, amount = 1): void {
    const key = labelKey(labels);
    this.#values.set(key, (this.#values.get(key) ?? 0) + amount);
  }

  get(labels: LabelValues = {}): number {
    return this.#values.get(labelKey(labels)) ?? 0;
  }

  render(): string[] {
    if (this.#values.size === 0) return [`${this.name} 0`];
    return [...this.#values].map(
      ([key, value]) => `${renderName(this.name, key)} ${value}`,
    );
  }
}

export class Gauge implements Metric {
  readonly name: string;
  readonly help: string;
  readonly type = 'gauge' as const;
  #value = 0;

  constructor(name: string, help: string) {
    this.name = name;
    this.help = help;
  }

  inc(amount = 1): void {
    this.#value += amount;
  }

  dec(amount = 1): void {
    this.#value -= amount;
  }

  set(value: number): void {
    this.#value = value;
  }

  get(): number {
    return this.#value;
  }

  render(): string[] {
    return [`${this.name} ${this.#value}`];
  }
}

export class Histogram implements Metric {
  readonly name: string;
  readonly help: string;
  readonly type = 'histogram' as const;
  readonly #buckets: readonly number[];
  readonly #counts: number[];
  #sum = 0;
  #count = 0;

  constructor(name: string, help: string, buckets: readonly number[]) {
    this.name = name;
    this.help = help;
    this.#buckets = [...buckets].sort((a, b) => a - b);
    this.#counts = this.#buckets.map(() => 0);
  }

  observe(value: number): void {
    this.#sum += value;
    this.#count += 1;
    for (const [index, bound] of this.#buckets.entries()) {
      if (value <= bound) this.#counts[index] = (this.#counts[index] ?? 0) + 1;
    }
  }

  count(): number {
    return this.#count;
  }

  render(): string[] {
    const lines: string[] = [];
    // `observe` increments every bucket whose bound covers the value, so the
    // counts are already cumulative, as the exposition format requires.
    for (const [index, bound] of this.#buckets.entries()) {
      lines.push(
        `${this.name}_bucket{le="${bound}"} ${this.#counts[index] ?? 0}`,
      );
    }
    lines.push(`${this.name}_bucket{le="+Inf"} ${this.#count}`);
    lines.push(`${this.name}_sum ${this.#sum}`);
    lines.push(`${this.name}_count ${this.#count}`);
    return lines;
  }
}

export type WebSocketMessageResult =
  'routed' | 'unknown_target' | 'too_large' | 'seq_regression' | 'malformed';

export type ApnsResultLabel = 'sent' | 'unregistered' | 'failed';

/**
 * The service's metric set. A facade rather than a free-form registry so every
 * emitted series is declared in one place and can be reviewed for leakage.
 */
export class Metrics {
  readonly #wsConnections = new Gauge(
    'kidscam_ws_connections',
    'Currently open signaling WebSocket connections on this instance.',
  );
  readonly #wsConnectionsTotal = new Counter(
    'kidscam_ws_connections_total',
    'Signaling WebSocket connections accepted since start.',
  );
  readonly #wsUpgradesRejected = new Counter(
    'kidscam_ws_upgrades_rejected_total',
    'Signaling WebSocket upgrades rejected, by reason.',
  );
  readonly #wsMessages = new Counter(
    'kidscam_ws_messages_total',
    'Signaling messages handled, by outcome.',
  );
  readonly #eventsAccepted = new Counter(
    'kidscam_events_accepted_total',
    'Detection events accepted for fan-out.',
  );
  readonly #eventFanout = new Histogram(
    'kidscam_event_fanout_seconds',
    'Time from accepting an event to the last APNs handoff.',
    [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  );
  readonly #apnsNotifications = new Counter(
    'kidscam_apns_notifications_total',
    'APNs notifications attempted, by result.',
  );
  readonly #apnsTokensDeleted = new Counter(
    'kidscam_apns_tokens_deleted_total',
    'Device rows deleted after APNs answered 410 Unregistered.',
  );

  wsConnectionOpened(): void {
    this.#wsConnections.inc();
    this.#wsConnectionsTotal.inc();
  }

  wsConnectionClosed(): void {
    this.#wsConnections.dec();
  }

  wsUpgradeRejected(reason: string): void {
    this.#wsUpgradesRejected.inc({ reason });
  }

  wsMessage(result: WebSocketMessageResult): void {
    this.#wsMessages.inc({ result });
  }

  eventAccepted(): void {
    this.#eventsAccepted.inc();
  }

  eventFanoutObserved(seconds: number): void {
    this.#eventFanout.observe(seconds);
  }

  apnsResult(result: ApnsResultLabel): void {
    this.#apnsNotifications.inc({ result });
  }

  apnsTokenDeleted(count = 1): void {
    this.#apnsTokensDeleted.inc({}, count);
  }

  /** Read accessors, for tests and for the `/metrics` renderer. */
  openConnections(): number {
    return this.#wsConnections.get();
  }

  apnsCount(result: ApnsResultLabel): number {
    return this.#apnsNotifications.get({ result });
  }

  render(): string {
    const metrics: Metric[] = [
      this.#wsConnections,
      this.#wsConnectionsTotal,
      this.#wsUpgradesRejected,
      this.#wsMessages,
      this.#eventsAccepted,
      this.#eventFanout,
      this.#apnsNotifications,
      this.#apnsTokensDeleted,
    ];

    const lines: string[] = [];
    for (const metric of metrics) {
      lines.push(`# HELP ${metric.name} ${metric.help}`);
      lines.push(`# TYPE ${metric.name} ${metric.type}`);
      lines.push(...metric.render());
    }
    return `${lines.join('\n')}\n`;
  }
}

export const METRICS_CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8';
