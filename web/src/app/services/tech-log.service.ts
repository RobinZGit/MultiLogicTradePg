import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { AppConfigService } from './app-config.service';

export type TechLogPhase = 'start' | 'end' | 'event';

export interface TechLogWriteEntry {
  trace_id: string;
  span_id: string;
  parent_span_id?: string | null;
  thread_key: string;
  source?: string;
  operation: string;
  phase: TechLogPhase;
  started_at?: string;
  finished_at?: string | null;
  duration_ms?: number | null;
  security_id?: number | null;
  timeframe_id?: number | null;
  sync_gen?: number | null;
  message?: string | null;
  payload?: Record<string, unknown> | null;
}

export interface TechLogRow extends TechLogWriteEntry {
  id: number;
  created_at: string;
}

const STORAGE_KEY = 'multilogic.techLogging';

@Injectable({ providedIn: 'root' })
export class TechLogService {
  private readonly pending: TechLogWriteEntry[] = [];
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly openSpans = new Map<
    string,
    { startedAt: number; entry: TechLogWriteEntry }
  >();

  enabled = false;

  constructor(
    private readonly http: HttpClient,
    private readonly appConfig: AppConfigService
  ) {
    this.enabled = localStorage.getItem(STORAGE_KEY) === '1';
  }

  setEnabled(on: boolean): void {
    this.enabled = on;
    localStorage.setItem(STORAGE_KEY, on ? '1' : '0');
    if (on) {
      this.event('tech-log', 'logging.enabled', 'Логирование включено');
    } else {
      this.flush(true);
    }
  }

  newTraceId(_securityId?: number, _syncGen?: number): string {
    return crypto.randomUUID();
  }

  threadKey(securityId: number, syncGen?: number | null, suffix?: string): string {
    const base =
      syncGen != null ? `sec:${securityId}:gen:${syncGen}` : `sec:${securityId}:main`;
    return suffix ? `${base}:${suffix}` : base;
  }

  start(
    traceId: string,
    threadKey: string,
    operation: string,
    opts?: {
      securityId?: number;
      timeframeId?: number;
      syncGen?: number;
      message?: string;
      payload?: Record<string, unknown>;
      parentSpanId?: string;
    }
  ): string {
    if (!this.enabled) {
      return '';
    }
    const spanId = crypto.randomUUID();
    const startedAt = Date.now();
    const entry: TechLogWriteEntry = {
      trace_id: traceId,
      span_id: spanId,
      parent_span_id: opts?.parentSpanId ?? null,
      thread_key: threadKey,
      source: 'web',
      operation,
      phase: 'start',
      started_at: new Date(startedAt).toISOString(),
      security_id: opts?.securityId ?? null,
      timeframe_id: opts?.timeframeId ?? null,
      sync_gen: opts?.syncGen ?? null,
      message: opts?.message ?? null,
      payload: opts?.payload ?? null,
    };
    this.openSpans.set(spanId, { startedAt, entry });
    this.enqueue(entry);
    return spanId;
  }

  end(
    spanId: string,
    opts?: { message?: string; payload?: Record<string, unknown> }
  ): void {
    if (!this.enabled || !spanId) {
      return;
    }
    const open = this.openSpans.get(spanId);
    if (!open) {
      return;
    }
    this.openSpans.delete(spanId);
    const finishedAt = Date.now();
    const durationMs = finishedAt - open.startedAt;
    this.enqueue({
      ...open.entry,
      phase: 'end',
      finished_at: new Date(finishedAt).toISOString(),
      duration_ms: durationMs,
      message: opts?.message ?? open.entry.message ?? null,
      payload: opts?.payload
        ? { ...(open.entry.payload ?? {}), ...opts.payload }
        : open.entry.payload ?? null,
    });
  }

  event(
    threadKey: string,
    operation: string,
    message: string,
    opts?: {
      traceId?: string;
      securityId?: number;
      timeframeId?: number;
      syncGen?: number;
      payload?: Record<string, unknown>;
    }
  ): void {
    if (!this.enabled) {
      return;
    }
    this.enqueue({
      trace_id: opts?.traceId ?? crypto.randomUUID(),
      span_id: crypto.randomUUID(),
      thread_key: threadKey,
      source: 'web',
      operation,
      phase: 'event',
      started_at: new Date().toISOString(),
      security_id: opts?.securityId ?? null,
      timeframe_id: opts?.timeframeId ?? null,
      sync_gen: opts?.syncGen ?? null,
      message,
      payload: opts?.payload ?? null,
    });
  }

  fetchRecent(opts?: {
    limit?: number;
    securityId?: number;
    traceId?: string;
  }) {
    const params = new URLSearchParams();
    if (opts?.limit) params.set('limit', String(opts.limit));
    if (opts?.securityId) params.set('security_id', String(opts.securityId));
    if (opts?.traceId) params.set('trace_id', String(opts.traceId));
    const q = params.toString();
    return this.http.get<{ rows: TechLogRow[] }>(
      `${this.appConfig.apiUrl}/tech-log${q ? `?${q}` : ''}`
    );
  }

  private enqueue(entry: TechLogWriteEntry): void {
    this.pending.push(entry);
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
    }
    this.flushTimer = setTimeout(() => this.flush(false), 250);
  }

  private flush(force: boolean): void {
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    if (this.pending.length === 0) {
      return;
    }
    const batch = this.pending.splice(0, 200);
    if (!this.enabled && !force) {
      return;
    }
    this.http
      .post<{ ok: boolean; inserted: number }>(
        `${this.appConfig.apiUrl}/tech-log`,
        { entries: batch }
      )
      .subscribe({ error: () => this.pending.unshift(...batch) });
  }
}
