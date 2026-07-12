import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { AppConfigService } from './app-config.service';
import { LogicRow } from '../models/logic.model';
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

  deleteLogic(id: number): Observable<{ ok: boolean; id: number }> {
    return this.http.delete<{ ok: boolean; id: number }>(
      `${this.appConfig.apiUrl}/logics/${id}`
    );
  }
}
