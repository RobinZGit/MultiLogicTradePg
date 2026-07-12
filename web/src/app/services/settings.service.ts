import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { AppConfigService } from './app-config.service';

export interface TbankTokenStatus {
  has_token: boolean;
}

@Injectable({ providedIn: 'root' })
export class SettingsService {
  constructor(
    private readonly http: HttpClient,
    private readonly appConfig: AppConfigService
  ) {}

  getTbankTokenStatus(): Observable<TbankTokenStatus> {
    return this.http.get<TbankTokenStatus>(
      `${this.appConfig.apiUrl}/settings/tbank-token`
    );
  }

  saveTbankToken(token: string): Observable<{ ok: boolean; has_token: boolean }> {
    return this.http.put<{ ok: boolean; has_token: boolean }>(
      `${this.appConfig.apiUrl}/settings/tbank-token`,
      { token }
    );
  }
}
