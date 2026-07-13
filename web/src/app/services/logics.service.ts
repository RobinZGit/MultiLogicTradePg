import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import { AppConfigService } from './app-config.service';
import { LogicIndicatorSignalRow, LogicRow, LogicParamsResponse, LogicSecurityRow, LogicStopRow, LogicTradingParamsPayload, LogicTradingParamsResponse } from '../models/logic.model';
import { LogicTradeLotRow, LogicTradeRow } from '../shared/logic-trade';
import { LogicPayload } from '../models/lookup.model';

@Injectable({ providedIn: 'root' })
export class LogicsService {
  constructor(
    private readonly http: HttpClient,
    private readonly appConfig: AppConfigService
  ) {}

  getLogics(): Observable<LogicRow[]> {
    return this.http.get<LogicRow[]>(`${this.appConfig.apiUrl}/logics`);
  }

  createLogic(payload: LogicPayload): Observable<LogicRow> {
    return this.http.post<LogicRow>(`${this.appConfig.apiUrl}/logics`, payload);
  }

  updateLogic(id: number, payload: LogicPayload): Observable<LogicRow> {
    return this.http.put<LogicRow>(
      `${this.appConfig.apiUrl}/logics/${id}`,
      payload
    );
  }

  updateLogicEnabled(
    id: number,
    is_enabled: boolean
  ): Observable<{ id: number; is_enabled: boolean }> {
    return this.http.patch<{ id: number; is_enabled: boolean }>(
      `${this.appConfig.apiUrl}/logics/${id}`,
      { is_enabled }
    );
  }

  getLogicParams(logicId: number): Observable<LogicParamsResponse> {
    return this.http.get<LogicParamsResponse>(
      `${this.appConfig.apiUrl}/logic-params`,
      { params: { logic_id: String(logicId) } }
    );
  }

  saveLogicParams(
    logicId: number,
    payload: LogicTradingParamsPayload
  ): Observable<LogicParamsResponse> {
    return this.http.put<LogicParamsResponse>(
      `${this.appConfig.apiUrl}/logic-params`,
      { logic_id: logicId, ...payload }
    );
  }

  updateLogicTradingParams(
    id: number,
    payload: LogicTradingParamsPayload
  ): Observable<LogicTradingParamsResponse> {
    return this.saveLogicParams(id, payload).pipe(
      map((r) => ({ id, ...r.trading }))
    );
  }

  deleteLogic(id: number): Observable<{ ok: boolean; id: number }> {
    return this.http.delete<{ ok: boolean; id: number }>(
      `${this.appConfig.apiUrl}/logics/${id}`
    );
  }

  getLogicIndicatorSignals(
    logicId: number
  ): Observable<LogicIndicatorSignalRow[]> {
    return this.http.get<LogicIndicatorSignalRow[]>(
      `${this.appConfig.apiUrl}/logic-indicator-signals`,
      { params: { logic_id: String(logicId) } }
    );
  }

  createLogicIndicatorSignal(body: {
    logic_id: number;
    indicator_id: number;
    position_side: 'long' | 'short';
    signal_kind: 'trend' | 'counter';
    formula: string;
  }): Observable<LogicIndicatorSignalRow> {
    return this.http.post<LogicIndicatorSignalRow>(
      `${this.appConfig.apiUrl}/logic-indicator-signals`,
      body
    );
  }

  updateLogicIndicatorSignal(
    id: number,
    body: { formula: string; is_active?: boolean }
  ): Observable<LogicIndicatorSignalRow> {
    return this.http.put<LogicIndicatorSignalRow>(
      `${this.appConfig.apiUrl}/logic-indicator-signals/${id}`,
      body
    );
  }

  deleteLogicIndicatorSignal(
    id: number
  ): Observable<{ ok: boolean; id: number }> {
    return this.http.delete<{ ok: boolean; id: number }>(
      `${this.appConfig.apiUrl}/logic-indicator-signals/${id}`
    );
  }

  getLogicStops(logicId: number): Observable<LogicStopRow[]> {
    return this.http.get<LogicStopRow[]>(
      `${this.appConfig.apiUrl}/logic-stops`,
      { params: { logic_id: String(logicId) } }
    );
  }

  createLogicStop(body: {
    logic_id: number;
    rule_kind: 'stop_loss' | 'take_profit';
    scope_type: 'security' | 'portfolio';
    value: number;
    value_unit: 'percent' | 'atr';
  }): Observable<LogicStopRow> {
    return this.http.post<LogicStopRow>(
      `${this.appConfig.apiUrl}/logic-stops`,
      body
    );
  }

  updateLogicStop(
    id: number,
    body: {
      scope_type?: 'security' | 'portfolio';
      value?: number;
      value_unit?: 'percent' | 'atr';
      is_active?: boolean;
    }
  ): Observable<LogicStopRow> {
    return this.http.put<LogicStopRow>(
      `${this.appConfig.apiUrl}/logic-stops/${id}`,
      body
    );
  }

  deleteLogicStop(id: number): Observable<{ ok: boolean; id: number }> {
    return this.http.delete<{ ok: boolean; id: number }>(
      `${this.appConfig.apiUrl}/logic-stops/${id}`
    );
  }

  getLogicSecurities(logicId: number): Observable<LogicSecurityRow[]> {
    return this.http.get<LogicSecurityRow[]>(
      `${this.appConfig.apiUrl}/logic-securities`,
      { params: { logic_id: String(logicId) } }
    );
  }

  addLogicSecuritiesBulk(
    logicId: number,
    securityIds: number[]
  ): Observable<LogicSecurityRow[]> {
    return this.http.post<LogicSecurityRow[]>(
      `${this.appConfig.apiUrl}/logic-securities/bulk`,
      { logic_id: logicId, security_ids: securityIds }
    );
  }

  deleteLogicSecurity(id: number): Observable<{ ok: boolean; id: number }> {
    return this.http.delete<{ ok: boolean; id: number }>(
      `${this.appConfig.apiUrl}/logic-securities/${id}`
    );
  }

  getLogicTrades(logicId: number, limit = 100): Observable<LogicTradeRow[]> {
    return this.http.get<LogicTradeRow[]>(
      `${this.appConfig.apiUrl}/logic-trades`,
      { params: { logic_id: String(logicId), limit: String(limit) } }
    );
  }

  getLogicTradeLots(tradeId: number): Observable<LogicTradeLotRow[]> {
    return this.http.get<LogicTradeLotRow[]>(
      `${this.appConfig.apiUrl}/logic-trade-lots`,
      { params: { trade_id: String(tradeId) } }
    );
  }

  closeAllPositionsAtMarket(logicId: number): Observable<{
    ok: boolean;
    closed?: number;
    skipped?: number;
    errors?: unknown[];
    error?: string;
  }> {
    return this.http.post<{
      ok: boolean;
      closed?: number;
      skipped?: number;
      errors?: unknown[];
      error?: string;
    }>(`${this.appConfig.apiUrl}/logic-trades/close-all`, { logic_id: logicId });
  }
}
