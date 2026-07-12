import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';

export interface AppConfig {
  apiUrl: string;
  finrespUrl: string;
}

const DEFAULT_CONFIG: AppConfig = {
  apiUrl: 'http://localhost:3000/api',
  finrespUrl: 'https://robinzgit.github.io/MultiLogicTradeA/finresp',
};

@Injectable({ providedIn: 'root' })
export class AppConfigService {
  private config: AppConfig = { ...DEFAULT_CONFIG };

  constructor(private readonly http: HttpClient) {}

  async load(): Promise<void> {
    try {
      const loaded = await firstValueFrom(
        this.http.get<AppConfig>('assets/app-config.json')
      );
      this.config = { ...DEFAULT_CONFIG, ...loaded };
    } catch {
      this.config = { ...DEFAULT_CONFIG };
    }
  }

  get apiUrl(): string {
    return this.config.apiUrl.replace(/\/$/, '');
  }

  get finrespUrl(): string {
    return this.config.finrespUrl;
  }
}

export function apiConnectionErrorMessage(apiUrl: string): string {
  return (
    `Не удалось подключиться к API базы данных (${apiUrl}). ` +
    'На локальном ПК запустите PostgreSQL и web\\MultiLogic_Trade_Progress_Start.bat. ' +
    'На GitHub Pages API недоступен — откройте приложение локально или укажите URL сервера в assets/app-config.json.'
  );
}
