/**
 * `/metrics`: the exposition format, where it is served, and — most
 * importantly — that it carries no identifiers.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { randomBytes } from 'node:crypto';
import { Metrics } from '../../src/metrics/registry.ts';
import { buildMetricsServer } from '../../src/server.ts';
import type { CameraCredentials, TestApp } from '../helpers/app.ts';
import {
  bootstrapCamera,
  bootstrapViewer,
  createTestApp,
  createTestContext,
  secondsOf,
  signRequest,
} from '../helpers/app.ts';

let harness: TestApp;

beforeEach(() => {
  harness = createTestApp();
});

afterEach(async () => {
  await harness.close();
});

describe('Metrics registry', () => {
  it('renders counters, gauges, and a histogram', () => {
    const metrics = new Metrics();
    metrics.wsConnectionOpened();
    metrics.wsConnectionOpened();
    metrics.wsConnectionClosed();
    metrics.wsMessage('routed');
    metrics.wsMessage('too_large');
    metrics.apnsResult('unregistered');
    metrics.eventFanoutObserved(0.2);
    metrics.eventFanoutObserved(3);

    const rendered = metrics.render();
    expect(rendered).toContain('kidscam_ws_connections 1');
    expect(rendered).toContain('kidscam_ws_connections_total 2');
    expect(rendered).toContain('kidscam_ws_messages_total{result="routed"} 1');
    expect(rendered).toContain(
      'kidscam_ws_messages_total{result="too_large"} 1',
    );
    expect(rendered).toContain(
      'kidscam_apns_notifications_total{result="unregistered"} 1',
    );
    expect(rendered).toContain('kidscam_event_fanout_seconds_count 2');
    expect(rendered).toContain('kidscam_event_fanout_seconds_sum 3.2');
    expect(rendered).toContain('# TYPE kidscam_event_fanout_seconds histogram');
  });

  it('accumulates histogram buckets cumulatively', () => {
    const metrics = new Metrics();
    metrics.eventFanoutObserved(0.01);
    metrics.eventFanoutObserved(0.4);
    const lines = metrics.render().split('\n');
    expect(lines).toContain('kidscam_event_fanout_seconds_bucket{le="0.05"} 1');
    expect(lines).toContain('kidscam_event_fanout_seconds_bucket{le="0.5"} 2');
    expect(lines).toContain('kidscam_event_fanout_seconds_bucket{le="+Inf"} 2');
  });
});

describe('GET /metrics', () => {
  it('is served unauthenticated in the Prometheus text format', async () => {
    const response = await harness.app.inject({
      method: 'GET',
      url: '/metrics',
    });
    expect(response.statusCode).toBe(200);
    expect(response.headers['content-type']).toContain('text/plain');
    expect(response.body).toContain('# HELP kidscam_ws_connections');
  });

  it('never exposes a pairing id, device id, or token', async () => {
    const camera: CameraCredentials = await bootstrapCamera(harness);
    harness.setNow(new Date(harness.now().getTime() + 1000));
    const viewer = await bootstrapViewer(harness, camera);
    harness.setNow(new Date(harness.now().getTime() + 1000));

    const ciphertext = randomBytes(48).toString('base64');
    await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/events',
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({ ciphertext }),
      }),
    );

    const response = await harness.app.inject({
      method: 'GET',
      url: '/metrics',
    });
    expect(response.body).toContain(
      'kidscam_apns_notifications_total{result="sent"} 1',
    );
    for (const secret of [
      camera.pairingId,
      camera.deviceId,
      viewer.deviceId,
      viewer.apnsToken,
      ciphertext,
      camera.kAuth.toString('base64'),
      camera.deviceKey.toString('base64'),
    ]) {
      expect(response.body).not.toContain(secret);
    }
  });

  it('is absent from the API listener when bound to its own port', async () => {
    const separate = createTestApp({ port: 8080, metricsPort: 9090 });
    const onApi = await separate.app.inject({ method: 'GET', url: '/metrics' });
    expect(onApi.statusCode).toBe(404);
    await separate.close();
  });

  it('is served by the standalone metrics listener', async () => {
    const base = createTestContext({ port: 8080, metricsPort: 9090 });
    const metricsApp = buildMetricsServer(base.ctx);
    const response = await metricsApp.inject({
      method: 'GET',
      url: '/metrics',
    });
    expect(response.statusCode).toBe(200);
    expect(response.body).toContain('kidscam_ws_connections');

    // Nothing else is reachable there.
    const health = await metricsApp.inject({
      method: 'GET',
      url: '/v1/health',
    });
    expect(health.statusCode).toBe(404);
    await metricsApp.close();
  });
});
