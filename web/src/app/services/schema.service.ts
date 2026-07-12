import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { AppConfigService } from './app-config.service';
import { DatabaseSchema, RoutineSource } from '../models/schema.model';

@Injectable({ providedIn: 'root' })
export class SchemaService {
  constructor(
    private readonly http: HttpClient,
    private readonly appConfig: AppConfigService
  ) {}

  getSchema(): Observable<DatabaseSchema> {
    return this.http.get<DatabaseSchema>(`${this.appConfig.apiUrl}/schema`);
  }

  getRoutineSource(oid: number): Observable<RoutineSource> {
    return this.http.get<RoutineSource>(
      `${this.appConfig.apiUrl}/schema/routine/${oid}/source`
    );
  }
}
